import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:vaster_checkpoint/vaster_checkpoint.dart';
import 'package:vaster_dis/tracer.dart';
import 'package:vaster_vm/vaster_vm.dart';

import '../vaster_command.dart';
import 'backend_resolver.dart';

/// `vaster resume <checkpoint.json>` — continue a durably parked pipeline.
///
/// The counterpart of `vaster run --checkpoint-dir`: rebuilds a fresh VM
/// (any backend — record on one, resume on another), restores every
/// subsystem from the checkpoint, optionally answers the pending
/// human-interaction request, and runs to completion. Subsequent gates
/// re-park when `--checkpoint-dir` is given, so a multi-gate pipeline can
/// hop across processes indefinitely.
class ResumeCommand extends VasterCommand {
  @override
  String get name => 'resume';

  @override
  String get description =>
      'Resumes a pipeline from a durable checkpoint file '
      '(see `vaster run --checkpoint-dir`).';

  @override
  ArgParser configureArgs(ArgParser parser) {
    parser.addOption(
      'backend',
      help: 'Model backend to resume on '
          '(fake|claude-api|claude-cli|gemini|gemini-cli|llama|rpc).',
    );
    parser.addOption('model', help: 'Backend-specific model name.');
    parser.addOption(
      'respond',
      help: 'Answer for the pending human request: approve, reject, or '
          'free-text.',
    );
    parser.addOption(
      'request',
      help: 'Request id being answered (defaults to the checkpoint\'s '
          'pending request).',
    );
    parser.addOption(
      'checkpoint-dir',
      help: 'Re-park durably at the NEXT human-interaction pause.',
    );
    parser.addFlag('trace',
        negatable: false, help: 'Live disassembly trace while resuming.');
    return parser;
  }

  @override
  Future<int> execute(CommandContext context) async {
    final out = context.stdoutSink;
    final err = context.stderrSink;
    final results = context.parsedResults;

    if (results.rest.isEmpty) {
      err.writeln('Usage: vaster resume <checkpoint.json> '
          '[--respond approve|reject|<text>] [--backend fake|...]');
      return 1;
    }
    final file = File(results.rest.first);
    if (!file.existsSync()) {
      err.writeln('Error: checkpoint file not found: ${file.path}');
      return 1;
    }

    final MachineCheckpoint checkpoint;
    try {
      checkpoint = MachineCheckpoint.fromJson(
          jsonDecode(file.readAsStringSync()) as Map<String, dynamic>);
    } on FormatException catch (e) {
      err.writeln('Error: invalid checkpoint: ${e.message}');
      return 1;
    }

    final pending = checkpoint.continuation.pendingRequest;
    final respondText = results['respond'] as String?;
    final requestId =
        results['request'] as String? ?? pending?.requestId;
    HumanInteractionResponse? response;
    if (respondText != null) {
      if (requestId == null) {
        err.writeln('Error: --respond given but no pending request in the '
            'checkpoint and no --request id.');
        return 1;
      }
      response = switch (respondText.toLowerCase()) {
        'approve' || 'yes' || 'y' =>
          HumanInteractionResponse.approve(requestId: requestId),
        'reject' || 'no' || 'n' => HumanInteractionResponse.reject(
            requestId: requestId, reason: 'Rejected via vaster resume.'),
        _ => HumanInteractionResponse.answer(
            requestId: requestId, answerText: respondText),
      };
    }

    final resolved =
        await resolveBackendModel(results: results, context: context, err: err);
    final model = resolved.model;
    final program = checkpoint.decodeProgram();

    out.writeln('======================================================================');
    out.writeln('  VASTER VM — DURABLE RESUME');
    out.writeln('  Program : ${program.programName} '
        '(${program.instructions.length} instructions)');
    out.writeln('  Suspended: ${checkpoint.capturedAt.toIso8601String()} '
        'at pc ${checkpoint.continuation.resumePc}');
    if (pending != null) {
      out.writeln('  Pending : ${pending.requestId} — ${pending.prompt}');
    }
    out.writeln('  Backend : ${model.modelName}');
    out.writeln('  Meters  : ${checkpoint.budgetConsumedTokens} tokens / '
        '\$${checkpoint.budgetConsumedCost.toStringAsFixed(6)} already spent');
    out.writeln('======================================================================\n');

    final vm = await VasterVMEngine.bootstrap(
        config: VMConfig(defaultModel: model));
    final usageMeter = ResumeUsageMeter();
    final usageSub = vm.eventBus.on<ModelUsageEvent>().listen(usageMeter.add);

    final runtime = await checkpoint.restoreRuntime(
      vm: vm,
      policy: ExecutionPolicy.unlimited,
      scheduler: BasicVasterScheduler(taskQueue: PriorityTaskQueue()),
    );

    ExecutionTracer? tracer;
    if (results['trace'] as bool? ?? false) {
      tracer = ExecutionTracer(runtime, sink: out.writeln)..attach();
    }

    var state = await checkpoint.resumeWith(runtime, respond: response);

    // Subsequent gates: re-park durably, or fall back to interactive stdin.
    final checkpointDir = results['checkpoint-dir'] as String?;
    while (state.status == RuntimeStatus.pausedForHuman) {
      final request = runtime.pendingHumanRequest;
      if (request == null) break;
      if (checkpointDir != null) {
        final next = MachineCheckpoint.capture(
            runtime: runtime, vm: vm, program: program);
        final path = '$checkpointDir/${program.programName}'
            '_${request.requestId}.ckpt.json';
        File(path)
          ..parent.createSync(recursive: true)
          ..writeAsStringSync(
              const JsonEncoder.withIndent('  ').convert(next.toJson()));
        out.writeln('\n── PARKED (durable) ────────────────────────────────────');
        out.writeln('  awaiting: ${request.prompt}');
        out.writeln('  checkpoint: $path');
        out.writeln('  resume: vaster resume $path --respond approve');
        // Same zero-copy prewarm as `vaster run`'s park: regions pinned
        // since the last park get frames too.
        final prewarmer = resolved.kvPrewarmer;
        if (prewarmer != null) {
          final stats =
              await prewarmer.prewarmPinnedRegions(vm.contextManager);
          if (stats.faults + stats.hits > 0) {
            out.writeln('  kv-prewarm: ${stats.faults} region(s) '
                'materialized (${stats.tokensMaterialized} tokens)'
                '${stats.hits > 0 ? ', ${stats.hits} already warm' : ''}'
                '${stats.invalidations > 0 ? ', ${stats.invalidations} stale mapping(s) evicted' : ''}');
          }
        }
        tracer?.detach();
        await Future<void>.delayed(Duration.zero);
        await usageSub.cancel();
        await vm.shutdown();
        await resolved.dispose();
        return 3;
      }
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
        await usageSub.cancel();
        await vm.shutdown();
        await resolved.dispose();
        return 2;
      }
      final reply = switch (answer.toLowerCase()) {
        'yes' || 'y' || 'approve' =>
          HumanInteractionResponse.approve(requestId: request.requestId),
        'no' || 'n' || 'reject' => HumanInteractionResponse.reject(
            requestId: request.requestId, reason: 'Rejected by user.'),
        _ => HumanInteractionResponse.answer(
            requestId: request.requestId, answerText: answer),
      };
      state = await runtime.resumeWithHumanResponse(reply);
    }

    tracer?.detach();
    await Future<void>.delayed(Duration.zero);
    await usageSub.cancel();

    out.writeln('\n── RESUME COMPLETE ────────────────────────────────────');
    out.writeln('  status : ${state.status.name}');
    out.writeln('  tokens : ${runtime.budget.consumedTokens} total '
        '(${runtime.budget.consumedTokens - checkpoint.budgetConsumedTokens} '
        'this resume)');
    if (runtime.budget.consumedCost > 0) {
      out.writeln(
          '  cost   : \$${runtime.budget.consumedCost.toStringAsFixed(6)}');
    }
    if (usageMeter.cacheReadTokens > 0) {
      out.writeln('  cache  : ${usageMeter.cacheReadTokens} of '
          '${usageMeter.promptTokens} prompt tokens restored from KV state '
          '— never re-decoded');
    }
    final resultRegister = program.resultBinding;
    if (resultRegister != null &&
        state.registers.containsKey(resultRegister)) {
      out.writeln('  output :');
      out.writeln('${state.registers[resultRegister]}');
    }
    if (state.status == RuntimeStatus.error) {
      err.writeln('\n${state.errorDetails}');
    }

    await vm.shutdown();
    await resolved.dispose();
    return state.status == RuntimeStatus.halted ? 0 : 1;
  }
}

/// Aggregates resume-side usage for the report.
class ResumeUsageMeter {
  int promptTokens = 0;
  int cacheReadTokens = 0;
  bool sawEstimates = false;

  void add(ModelUsageEvent event) {
    promptTokens += event.promptTokenCount;
    cacheReadTokens += (event.usage['cacheReadTokenCount'] as int?) ?? 0;
    if (event.estimated) sawEstimates = true;
  }
}
