import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:vaster_model_claude_api/vaster_model_claude_api.dart';
import 'package:vaster_model_claude_cli/vaster_model_claude_cli.dart';
import 'package:vaster_model_fake/vaster_model_fake.dart';
import 'package:vaster_model_gemini_cli/vaster_model_gemini_cli.dart';
import 'package:vaster_model_google_ai/vaster_model_google_ai.dart';
import 'package:vaster_model_rpc/vaster_model_rpc.dart';
import 'package:vaster_replay/vaster_replay.dart';
import 'package:vaster_vm/vaster_vm.dart';

import '../vaster_command.dart';

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
        'rpc',
      ],
      help: 'Model backend for compiled program execution '
          '(fake = offline echo model, rpc = sidecar socket).',
    );
    parser.addOption(
      'model',
      abbr: 'm',
      help: 'Backend model id (e.g. claude-opus-5, gemini-2.0-flash).',
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
      help: 'Record an execution journal to the given file for time-travel '
          'replay (compiled programs only).',
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

    // 2. Resolve the model backend. Real network backends are wrapped in the
    //    resilience layer: transient failures (429/5xx/timeouts) retry with
    //    exponential backoff instead of trapping the VM.
    VasterModel resilient(VasterModel backend) => ResilientVasterModel(
          primary: backend,
          retryPolicy: const RetryPolicy(
            maxAttempts: 3,
            attemptTimeout: Duration(minutes: 2),
          ),
          onRetry: (event) => err.writeln('  [retry] $event'),
        );

    final VasterModel model = switch (backend) {
      'claude-api' => resilient(ClaudeApiVasterModel(
          targetModel: results['model'] as String? ?? 'claude-opus-5')),
      'claude-cli' => resilient(ClaudeCliVasterModel(
          selectedModel: results['model'] as String?,
          workingDirectory: context.workingDirectory)),
      'gemini' => resilient(GoogleAiVasterModel(
          apiKey: Platform.environment['GEMINI_API_KEY'] ??
              Platform.environment['GOOGLE_AI_API_KEY'],
          targetModel: results['model'] as String? ?? 'gemini-2.0-flash')),
      'gemini-cli' => resilient(GeminiCliVasterModel(
          selectedModel: results['model'] as String?,
          workingDirectory: context.workingDirectory)),
      'rpc' => resilient(RpcVasterModel(socketPath: context.socketPath)),
      _ => FakeVasterModel(),
    };

    out.writeln('======================================================================');
    out.writeln('  VASTER VM — COMPILED PROGRAM EXECUTION                               ');
    out.writeln('  Program : ${program.programName} (${program.instructions.length} instructions)');
    out.writeln('  Backend : $backend (${model.modelName})');
    out.writeln('======================================================================\n');

    // 3. Bootstrap and execute.
    final vm = await VasterVMEngine.bootstrap(
        config: VMConfig(defaultModel: model));
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
    final recordPath = results['record'] as String?;
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

    // 4. Interactive human-in-the-loop resume.
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
      File(recordPath).writeAsStringSync(
          const JsonEncoder.withIndent('  ').convert(recorder.journal.toJson()));
      out.writeln('\n[record] ${recorder.recordedSteps} steps → $recordPath');
    }
    if (eventSub != null) {
      // Let the broadcast stream flush events published this turn.
      await Future<void>.delayed(Duration.zero);
      await eventSub.cancel();
    }

    // 5. Report.
    out.writeln('\n── EXECUTION COMPLETE ─────────────────────────────────');
    out.writeln('  status : ${state.status.name}');
    out.writeln('  tokens : ${budget.consumedTokens}');
    if (state.registers.containsKey('__output__')) {
      out.writeln('  output :');
      out.writeln('${state.registers['__output__']}');
    }
    if (state.status == RuntimeStatus.error) {
      err.writeln('\n${state.errorDetails}');
    }

    await vm.shutdown();
    return state.status == RuntimeStatus.halted ? 0 : 1;
  }
}
