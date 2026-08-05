import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:vaster_checkpoint/vaster_checkpoint.dart';
import 'package:vaster_replay/vaster_replay.dart';
import 'package:vaster_vm/vaster_vm.dart';
import 'package:vaster_dis/tracer.dart';

import '../vaster_command.dart';
import 'backend_resolver.dart';

class RunCommand extends VasterCommand {
  @override
  String get name => 'run';

  @override
  List<String> get aliases => const [];

  @override
  String get description =>
      'Executes a compiled Vaster program (.vbc/.json) on the VM, '
      'or compiles and runs an AST pipeline script (.dart).';

  @override
  void configureArgs(ArgParser parser) {
    parser.addOption(
      'backend',
      abbr: 'b',
      defaultsTo: 'fake',
      allowed: const [
        'fake',
        'claude-api',
        'claude-cli',
        'gemini',
        'gemini-cli',
        'llama',
        'rpc',
      ],
      help: 'Model backend for compiled program execution '
          '(fake = offline echo model, llama = in-process llama.cpp over '
          'FFI with zero-copy KV frames, rpc = sidecar socket).',
    );
    parser.addOption(
      'model',
      abbr: 'm',
      help: 'Backend model id (e.g. claude-opus-5, gemini-2.0-flash).',
    );
    parser.addOption(
      'checkpoint-dir',
      help: 'Durable parking: on a human-interaction pause, write a '
          'self-contained checkpoint file to this directory and exit '
          '(code 3) instead of prompting interactively. Resume later with '
          '`vaster resume <file>`.',
    );
    parser.addFlag(
      'trace',
      abbr: 't',
      help: 'Live disassembly-style execution trace (compiled programs only).',
      negatable: false,
    );
    parser.addFlag(
      'events',
      abbr: 'e',
      help: 'Print the VM runtime event stream as JSON lines '
          '(compiled programs only).',
      negatable: false,
    );
    parser.addOption(
      'record',
      abbr: 'r',
      help: 'Record a replay envelope (execution journal + model I/O tape) '
          'to the given file (compiled programs only).',
    );
    parser.addOption(
      'replay',
      help: 'Deterministically re-execute from a recorded envelope: model '
          'calls are answered from its tape — zero tokens, zero network. '
          'Overrides --backend.',
    );
    parser.addOption(
      'cores',
      abbr: 'c',
      help: 'Virtual core count for the VM scheduler: how many scheduled '
          'quanta may be in flight concurrently (model I/O overlaps across '
          'jobs). Default 1.',
    );
  }

  @override
  Future<int> execute(CommandContext context) async {
    final args = context.parsedResults.rest;
    final out = context.stdoutSink;
    final err = context.stderrSink;

    if (args.isEmpty) {
      err.writeln('Error: Missing program path.');
      err.writeln('Usage: vaster run <program.vbc | program.json | script.dart> '
          '[--backend fake|claude-api|gemini] [--trace]');
      return 1;
    }

    final targetPath = args.first;
    final file = File(targetPath);

    if (!file.existsSync()) {
      err.writeln('Error: File not found at $targetPath');
      return 1;
    }

    // Compiled program artifacts execute in-process on the VM.
    if (targetPath.endsWith('.vbc') || targetPath.endsWith('.json')) {
      return _executeCompiledProgram(context, file);
    }

    // AST pipeline scripts run through the Dart VM as before.
    out.writeln('======================================================================');
    out.writeln('  VASTER PIPELINE EXECUTION ENGINE                                     ');
    out.writeln('  Executing: $targetPath                                               ');
    out.writeln('======================================================================\n');

    final process = await Process.start(
      'dart',
      ['run', targetPath],
      workingDirectory: context.workingDirectory,
    );

    final stdoutSub = process.stdout.transform(utf8.decoder).listen((data) => out.write(data));
    final stderrSub = process.stderr.transform(utf8.decoder).listen((data) => err.write(data));

    final exitCode = await process.exitCode;
    await stdoutSub.cancel();
    await stderrSub.cancel();

    return exitCode;
  }

  Future<int> _executeCompiledProgram(CommandContext context, File file) async {
    final out = context.stdoutSink;
    final err = context.stderrSink;
    final results = context.parsedResults;
    final backend = results['backend'] as String? ?? 'fake';
    final trace = results['trace'] as bool? ?? false;

    // 1. Load the program (binary or JSON).
    final VasterProgram program;
    try {
      if (file.path.endsWith('.vbc')) {
        program = VasterProgramBinary.fromBytes(file.readAsBytesSync());
      } else {
        program = VasterProgram.fromJson(
            jsonDecode(file.readAsStringSync()) as Map<String, dynamic>);
      }
    } on VbcDecodeException catch (e) {
      err.writeln('Error: $e');
      return 1;
    } on FormatException catch (e) {
      err.writeln('Error: invalid program JSON: ${e.message}');
      return 1;
    }

    // 2. Resolve the model backend (shared with `vaster resume`).
    final resolved =
        await resolveBackendModel(results: results, context: context, err: err);
    VasterModel model = resolved.model;

    // Deterministic replay: answer every model call from a recorded tape.
    final replayPath = results['replay'] as String?;
    if (replayPath != null) {
      final envelope = jsonDecode(File(replayPath).readAsStringSync())
          as Map<String, dynamic>;
      model = ReplayVasterModel(
          tape: ModelTape.fromJson(
              Map<String, dynamic>.from(envelope['modelTape'] as Map? ?? {})));
    }

    // Recording: capture model I/O onto a tape alongside the step journal.
    final recordPath = results['record'] as String?;
    ModelTape? recordingTape;
    if (recordPath != null) {
      recordingTape = ModelTape();
      model = RecordingVasterModel(inner: model, tape: recordingTape);
    }

    out.writeln('======================================================================');
    out.writeln('  VASTER VM — COMPILED PROGRAM EXECUTION                               ');
    out.writeln('  Program : ${program.programName} (${program.instructions.length} instructions)');
    out.writeln('  Backend : ${replayPath != null ? 'replay tape ($replayPath)' : '$backend (${model.modelName})'}');
    out.writeln('======================================================================\n');

    // 3. Bootstrap and execute.
    final vm = await VasterVMEngine.bootstrap(
        config: VMConfig(
      defaultModel: model,
      cores: int.tryParse(results['cores'] as String? ?? '') ?? 1,
    ));
    final usageMeter = _UsageMeter();
    final usageSub = vm.eventBus.on<ModelUsageEvent>().listen(usageMeter.add);
    final budget = ExecutionBudget.unlimited();
    final runtime = VasterRuntime(
      vm: vm,
      policy: ExecutionPolicy.unlimited,
      budget: budget,
      scheduler: BasicVasterScheduler(taskQueue: PriorityTaskQueue()),
    );

    ExecutionTracer? tracer;
    if (trace) {
      tracer = ExecutionTracer(runtime, sink: out.writeln)..attach();
    }

    // Journal recording chains with the tracer through the step observer.
    VasterExecutionRecorder? recorder;
    if (recordPath != null) {
      recorder = VasterExecutionRecorder()..attach(runtime);
    }

    // Runtime event stream as JSON lines — the telemetry bus made visible.
    StreamSubscription<RuntimeEvent>? eventSub;
    if (results['events'] as bool? ?? false) {
      eventSub = vm.eventBus.stream
          .listen((event) => out.writeln('[evt] ${jsonEncode(event.toJson())}'));
    }

    var state = await runtime.executeProgram(program);

    // 4. Durable parking: with --checkpoint-dir the pause becomes a
    //    checkpoint file and the process exits — the pipeline no longer
    //    holds a process hostage while a human thinks.
    final checkpointDir = results['checkpoint-dir'] as String?;
    if (checkpointDir != null &&
        state.status == RuntimeStatus.pausedForHuman) {
      final request = runtime.pendingHumanRequest;
      final checkpoint = MachineCheckpoint.capture(
          runtime: runtime, vm: vm, program: program);
      final path = '$checkpointDir/${program.programName}'
          '_${request?.requestId ?? 'paused'}.ckpt.json';
      File(path)
        ..parent.createSync(recursive: true)
        ..writeAsStringSync(
            const JsonEncoder.withIndent('  ').convert(checkpoint.toJson()));
      out.writeln('\n── PARKED (durable) ────────────────────────────────────');
      if (request != null) {
        out.writeln('  awaiting: ${request.prompt}');
      }
      out.writeln('  checkpoint: $path');
      // Zero-copy prewarm: pinned regions become shared KV frames so the
      // resuming process restores state instead of re-decoding the prefix.
      final prewarmer = resolved.kvPrewarmer;
      if (prewarmer != null) {
        final (regions, tokens) =
            await prewarmer.prewarmPinnedRegions(vm.contextManager);
        if (regions > 0) {
          out.writeln('  kv-prewarm: $regions pinned region(s) → '
              'shared frames ($tokens tokens)');
        }
      }
      out.writeln('  resume: vaster resume $path --respond approve');
      tracer?.detach();
      recorder?.detach();
      await Future<void>.delayed(Duration.zero);
      await usageSub.cancel();
      await eventSub?.cancel();
      await vm.shutdown();
      return 3;
    }

    // Interactive human-in-the-loop resume.
    while (state.status == RuntimeStatus.pausedForHuman) {
      final request = runtime.pendingHumanRequest;
      if (request == null) break;
      out.writeln('\n── HUMAN INTERACTION REQUIRED ──────────────────────────');
      out.writeln('  ${request.prompt}');
      if (request.options.isNotEmpty) {
        out.writeln('  options: ${request.options.join(' / ')}');
      }
      out.write('> ');
      final answer = stdin.readLineSync()?.trim();
      if (answer == null || answer.isEmpty) {
        err.writeln('No input available — leaving program paused.');
        tracer?.detach();
        recorder?.detach();
        await eventSub?.cancel();
        await vm.shutdown();
        return 2;
      }
      final response = switch (answer.toLowerCase()) {
        'yes' || 'y' || 'approve' =>
          HumanInteractionResponse.approve(requestId: request.requestId),
        'no' || 'n' || 'reject' => HumanInteractionResponse.reject(
            requestId: request.requestId, reason: 'Rejected by user.'),
        _ => HumanInteractionResponse.answer(
            requestId: request.requestId, answerText: answer),
      };
      state = await runtime.resumeWithHumanResponse(response);
    }

    tracer?.detach();

    if (recorder != null && recordPath != null) {
      recorder.detach();
      // The replay envelope: step journal + model I/O tape together are a
      // complete, deterministic re-execution recipe (`--replay <file>`).
      File(recordPath).writeAsStringSync(
          const JsonEncoder.withIndent('  ').convert({
        // The program makes the envelope self-contained for `vaster debug`
        // (older envelopes lack it and need --program).
        'program': program.toJson(),
        'journal': recorder.journal.toJson(),
        'modelTape': recordingTape?.toJson() ?? ModelTape().toJson(),
      }));
      out.writeln('\n[record] ${recorder.recordedSteps} steps + '
          '${recordingTape?.length ?? 0} model calls → $recordPath');
    }
    // Let the broadcast stream flush events published this turn.
    await Future<void>.delayed(Duration.zero);
    await usageSub.cancel();
    if (eventSub != null) {
      await eventSub.cancel();
    }

    // 5. Report.
    out.writeln('\n── EXECUTION COMPLETE ─────────────────────────────────');
    out.writeln('  status : ${state.status.name}');
    out.writeln('  tokens : ${budget.consumedTokens}');
    if (budget.consumedCost > 0) {
      out.writeln('  cost   : \$${budget.consumedCost.toStringAsFixed(6)}');
    }
    if (usageMeter.promptTokens > 0 && usageMeter.cacheReadTokens > 0) {
      final share = usageMeter.cacheReadTokens / usageMeter.promptTokens * 100;
      out.writeln('  cache  : ${usageMeter.cacheReadTokens} of '
          '${usageMeter.promptTokens} prompt tokens read from cache '
          '(${share.toStringAsFixed(1)}%)');
    }
    if (usageMeter.sawEstimates) {
      out.writeln('  note   : some usage was length-estimated, not '
          'backend-reported');
    }
    // Program-declared result (header metadata); legacy programs used the
    // __output__ register convention.
    final resultRegister = program.resultBinding ??
        (state.registers.containsKey('__output__') ? '__output__' : null);
    if (resultRegister != null && state.registers.containsKey(resultRegister)) {
      out.writeln('  output :');
      out.writeln('${state.registers[resultRegister]}');
    }
    if (state.status == RuntimeStatus.error) {
      err.writeln('\n${state.errorDetails}');
    }

    await vm.shutdown();
    return state.status == RuntimeStatus.halted ? 0 : 1;
  }
}

/// Aggregates [ModelUsageEvent]s for the final report: total prompt tokens,
/// cache-read share, and whether any usage was estimated.
class _UsageMeter {
  int promptTokens = 0;
  int cacheReadTokens = 0;
  bool sawEstimates = false;

  void add(ModelUsageEvent event) {
    promptTokens += event.promptTokenCount;
    cacheReadTokens += (event.usage['cacheReadTokenCount'] as int?) ?? 0;
    if (event.estimated) sawEstimates = true;
  }
}
