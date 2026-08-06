import 'dart:convert';
import 'dart:io';

import 'package:vaster_ast/vaster_ast.dart';
import 'package:vaster_compiler/vaster_compiler.dart';
import 'package:vaster_domain/vaster_domain.dart';
import 'package:vaster_replay/vaster_replay.dart';
import 'package:vaster_vm/vaster_vm.dart';

/// Refreshes `test/fixtures/sdd_fidelity.replay.json` after a frontend
/// change that alters the compiled program or the model-visible prompts:
/// the OLD tape's real recorded responses are replayed **sequentially**
/// (fingerprints are being re-derived, so fingerprint matching cannot be
/// used) through the CURRENT toolchain, re-recording a fresh envelope —
/// program, journal, and tape — at zero token cost.
///
///     dart run tool/refresh_sdd_fixture.dart
///
/// The real run behind the responses: claude-cli, 2026-08-05 —
/// 450,302 tokens, $0.825917 wire cost. Those numbers ride the responses
/// verbatim, so the fidelity test's assertions keep locking them.
Future<void> main() async {
  final fixture = File('test/fixtures/sdd_fidelity.replay.json');
  final old = const ReplayEnvelopeCodec()
      .decode(jsonDecode(fixture.readAsStringSync()) as Map<String, dynamic>);

  // The in-repo SDD pipeline — must stay in lockstep with
  // test/sdd_fidelity_replay_test.dart and test/debug_session_test.dart.
  const architect = AgentRole(
      roleId: 'architect',
      name: 'Architect',
      title: 'Principal Architect',
      instruction: 'You write precise, reviewable specifications.');
  const lead = AgentRole(
      roleId: 'lead',
      name: 'Lead',
      title: 'Tech Lead',
      instruction: 'You turn specs into concrete implementation plans.');
  const reviewer = AgentRole(
      roleId: 'reviewer',
      name: 'Reviewer',
      title: 'Staff Reviewer',
      instruction: 'You review artifacts rigorously.');
  const pipeline = Pipeline(
    name: 'sdd_prompt_calibration',
    result: Binding('review'),
    roles: [architect, lead, reviewer],
    mounts: [StorageMount(mountPrefix: '/workspace')],
    children: [
      Specify(
        goal: 'Add a --version flag to a small command-line tool: it '
            'prints the tool version and exits 0. Keep the spec under 300 '
            'words.',
        agent: architect,
      ),
      Plan(agent: lead),
      Review(agent: reviewer),
    ],
  );
  final program = const BasicWorkflowCompiler().compile(pipeline);

  final sequential = _SequentialTapeModel(old.tape);
  final newTape = ModelTape();
  final recording = RecordingVasterModel(inner: sequential, tape: newTape);

  final vm = await VasterVMEngine.bootstrap(
      config: VMConfig(defaultModel: recording));
  final runtime = VasterRuntime(
    vm: vm,
    policy: ExecutionPolicy.unlimited,
    budget: ExecutionBudget.unlimited(),
    scheduler: BasicVasterScheduler(taskQueue: PriorityTaskQueue()),
  );
  final recorder = VasterExecutionRecorder()..attach(runtime);

  final state = await runtime.executeProgram(program);
  recorder.detach();
  if (state.status != RuntimeStatus.halted) {
    stderr.writeln('refresh run did not halt: ${state.errorDetails}');
    exitCode = 1;
    return;
  }
  if (sequential.served != old.tape.entries.length) {
    stderr.writeln('refresh consumed ${sequential.served} of '
        '${old.tape.entries.length} recorded responses — call structure '
        'drifted, a plain re-record is required.');
    exitCode = 1;
    return;
  }

  fixture.writeAsStringSync(const JsonEncoder.withIndent('  ')
      .convert(const ReplayEnvelopeCodec().encode(
    programJson: program.toJson(),
    journalJson: recorder.journal.toJson(),
    tape: newTape,
  )));
  stdout.writeln('refreshed: ${fixture.path} '
      '(${program.instructions.length} instructions, '
      '${recorder.journal.frames.length} frames, '
      '${newTape.entries.length} tape entries)');
  await vm.shutdown();
}

/// Serves the old tape's responses strictly in recorded order — the
/// migration stand-in for when prompts changed and fingerprints cannot
/// match. Presents the ORIGINAL backend's identity and capabilities so
/// requests compile exactly as they would against it.
final class _SequentialTapeModel implements VasterModel {
  final ModelTape tape;
  int served = 0;

  _SequentialTapeModel(this.tape);

  @override
  String get modelName => tape.recordedModelName ?? 'claude-cli';

  @override
  ModelCapabilities get capabilities =>
      tape.recordedCapabilities ??
      const ModelCapabilities(
        maxContextTokens: 128000,
        maxOutputTokens: 8192,
        supportsStreaming: true,
        supportsFunctionCalling: true,
        supportsVision: false,
        supportsSystemInstruction: true,
        supportsReasoning: false,
      );

  @override
  Future<ModelResponse> generate(ModelRequest request) async {
    if (served >= tape.entries.length) {
      throw StateError('sequential refresh ran past the recorded tape '
          '(${tape.entries.length} entries) — call structure drifted.');
    }
    return ModelResponse.fromJson(tape.entries[served++].responseJson);
  }

  @override
  Stream<ModelResponseChunk> generateStream(ModelRequest request) =>
      throw UnimplementedError('the ISA runtime never streams');
}
