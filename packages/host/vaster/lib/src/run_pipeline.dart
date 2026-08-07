import 'dart:convert';
import 'dart:io';

import 'package:vaster_ast/vaster_ast.dart';
import 'package:vaster_compiler/vaster_compiler.dart';
import 'package:vaster_replay/vaster_replay.dart';
import 'package:vaster_vm/vaster_vm.dart';

/// One file the pipeline wrote, as reported by the machine's own
/// [FileOperationEvent] stream — the report states what the program wrote,
/// never a directory listing of a mount target (AST_REVIEW §6.5).
final class PipelineArtifact {
  final String path;
  final int sizeBytes;

  const PipelineArtifact({required this.path, required this.sizeBytes});

  @override
  String toString() => '$path ($sizeBytes bytes)';
}

/// What one [runPipeline] call did: the halted (or paused) machine state,
/// the declared result value, the consumed meters, the files the program
/// wrote, and where the recording landed.
final class RunReport {
  final RuntimeState state;

  /// Value of the pipeline's declared `result:` binding; null when the
  /// pipeline declares none or execution stopped before it was written.
  final Object? result;

  final int consumedTokens;
  final double consumedCost;

  /// Files written by the program, in write order (re-writes keep the
  /// last size), from the run's own [FileOperationEvent]s.
  final List<PipelineArtifact> artifacts;

  /// Path of the recorded replay envelope; null when `record:` was not set.
  final String? envelopePath;

  /// Non-fatal warnings the run emitted (`code: message @pcN`) — chiefly
  /// unresolved `${…}` interpolations and unpaired transaction ops. A
  /// halted run with warnings is a run that did something the author
  /// probably did not intend (e.g. a file written to a literal
  /// `${path}` because a binding never resolved). Surfaced here so those
  /// stay loud instead of dying on the event bus.
  final List<String> warnings;

  const RunReport({
    required this.state,
    required this.result,
    required this.consumedTokens,
    required this.consumedCost,
    required this.artifacts,
    required this.envelopePath,
    this.warnings = const [],
  });

  bool get succeeded => state.status == RuntimeStatus.halted;

  @override
  String toString() {
    final buffer = StringBuffer()
      ..writeln('status  : ${state.status.name}')
      ..writeln('tokens  : $consumedTokens'
          '${consumedCost > 0 ? ' · cost \$${consumedCost.toStringAsFixed(4)}' : ''}');
    if (artifacts.isNotEmpty) {
      buffer.writeln('artifacts:');
      for (final artifact in artifacts) {
        buffer.writeln('  $artifact');
      }
    }
    if (envelopePath != null) buffer.writeln('envelope: $envelopePath');
    if (warnings.isNotEmpty) {
      buffer.writeln('warnings: ${warnings.length}');
      for (final warning in warnings) {
        buffer.writeln('  ⚠ $warning');
      }
    }
    if (state.status == RuntimeStatus.error) buffer.writeln('error   : ${state.errorDetails}');
    if (result != null) buffer.writeln('result  :\n$result');
    return buffer.toString();
  }
}

/// Compiles and executes [pipeline] on [backend], returning a [RunReport] —
/// the `runApp` of vaster (AST_REVIEW F0). Owns the whole harness every
/// host previously hand-assembled: compile, VM bootstrap, runtime
/// composition (unlimited policy; [budget] defaults to unlimited),
/// execution, artifact/meter collection, optional recording, and VM
/// teardown on every path.
///
/// The model choice stays explicit and required — the caller owns it
/// (Rule 5). When [record] is set, the run's model I/O and step journal
/// are written there as a replay envelope (`vaster debug`, `vaster
/// replay`, `--resume-at` all read it).
///
/// A HITL pause returns the paused report as-is: parking, prompting, and
/// resuming are host policy (`vaster run --checkpoint-dir` keeps its
/// richer loop).
Future<RunReport> runPipeline(
  Pipeline pipeline, {
  required VasterModel backend,
  ExecutionBudget? budget,
  String? record,
  Map<ModelDescriptor, VasterModel> models = const {},
  List<CodeSandbox> sandboxes = const [],
}) async {
  final program = const BasicWorkflowCompiler().compile(pipeline);

  final tape = ModelTape();
  final model = record != null ? RecordingVasterModel(inner: backend, tape: tape) : backend;

  final vm = await VasterVMEngine.bootstrap(
    config: VMConfig(defaultModel: model),
    initialSandboxes: sandboxes,
  );
  // Named models for SelectModel / descriptor-declared agents. When
  // recording, every registered model rides the SAME tape as the default —
  // one recording, whole run.
  for (final entry in models.entries) {
    vm.registerModel(
      entry.key,
      record != null ? RecordingVasterModel(inner: entry.value, tape: tape) : entry.value,
    );
  }
  try {
    final runtime = VasterRuntime(
      vm: vm,
      policy: ExecutionPolicy.unlimited,
      budget: budget ?? ExecutionBudget.unlimited(),
      scheduler: BasicVasterScheduler(taskQueue: PriorityTaskQueue()),
    );

    final written = <String, int>{};
    final fileSub = vm.eventBus.on<FileOperationEvent>().listen((event) {
      if (event.operation == FileOperationType.write) written[event.path] = event.sizeBytes;
    });
    final warnings = <String>[];
    final warnSub = vm.eventBus.on<RuntimeWarningEvent>().listen(
          (event) => warnings.add('${event.code}: ${event.message} @pc${event.pc}'),
        );
    final recorder = record != null ? (VasterExecutionRecorder()..attach(runtime)) : null;

    final state = await runtime.executeProgram(program);

    recorder?.detach();
    // Event delivery is async — flush the microtask queue before
    // cancelling, or the final writes never reach the listener (the same
    // idiom the CLI's resume loop uses).
    await Future<void>.delayed(Duration.zero);
    await fileSub.cancel();
    await warnSub.cancel();

    if (record != null) {
      File(record)
        ..parent.createSync(recursive: true)
        ..writeAsStringSync(
          jsonEncode(
            const ReplayEnvelopeCodec().encode(
              programJson: program.toJson(),
              journalJson: recorder!.journal.toJson(),
              tape: tape,
            ),
          ),
        );
    }

    return RunReport(
      state: state,
      result: program.resultBinding == null ? null : state.registers[program.resultBinding],
      consumedTokens: runtime.budget.consumedTokens,
      consumedCost: runtime.budget.consumedCost,
      artifacts: [
        for (final entry in written.entries) PipelineArtifact(path: entry.key, sizeBytes: entry.value),
      ],
      envelopePath: record,
      warnings: warnings,
    );
  } finally {
    await vm.shutdown();
  }
}
