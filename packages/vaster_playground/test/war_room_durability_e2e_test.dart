import 'dart:convert';

import 'package:test/test.dart';
import 'package:vaster_checkpoint/vaster_checkpoint.dart';
import 'package:vaster_compiler/vaster_compiler.dart';
import 'package:vaster_replay/vaster_replay.dart';
import 'package:vaster_vm/vaster_vm.dart';

import 'harness/war_room_harness.dart';

/// DE-P5: the full war-room pipeline survives process death at its gate.
///
/// The compiler-level counterpart of the checkpoint package's ISA-level
/// kill-safety test: the richest program the framework can express — agents,
/// tool loop, parallel dispatch, messaging, sandbox, transactions, Decide —
/// pauses at its approval gate, is captured to JSON, loses every live
/// object, and completes identically in a fresh VM. Plus the replay
/// interplay: a run whose model calls were answered from a recorded tape
/// checkpoints and resumes just the same.
void main() {
  const compiler = BasicWorkflowCompiler();

  Future<(VasterVMEngine, VasterRuntime)> boot(VasterModel model) async {
    final vm = await VasterVMEngine.bootstrap(
      config: VMConfig(defaultModel: model),
      initialTools: [buildRegistryTool()],
    );
    final runtime = VasterRuntime(
      vm: vm,
      policy: ExecutionPolicy.unlimited,
      budget: ExecutionBudget.unlimited(),
      scheduler: BasicVasterScheduler(taskQueue: PriorityTaskQueue()),
    );
    return (vm, runtime);
  }

  test('the war room dies at its gate and launches from JSON in a fresh VM',
      () async {
    final program = compiler.compile(warRoom());

    // ── Act I: run to the gate, checkpoint, die ──
    final (vmA, runtimeA) = await boot(buildModel());
    final paused = await runtimeA.executeProgram(program);
    expect(paused.status, RuntimeStatus.pausedForHuman,
        reason: 'error: ${paused.errorDetails}');
    expect(runtimeA.pendingHumanRequest?.requestId, 'launch_gate');
    // The sealed phase carries the request it waits on (MS-P6).
    expect(
      runtimeA.phase,
      isA<PhasePausedForHuman>().having(
          (p) => p.request.requestId, 'request', 'launch_gate'),
    );

    final checkpointJson = jsonEncode(MachineCheckpoint.capture(
      runtime: runtimeA,
      vm: vmA,
      program: program,
    ).toJson());
    await vmA.shutdown();

    // ── Act II: fresh VM, JSON only ──
    final restored = MachineCheckpoint.fromJson(
        jsonDecode(checkpointJson) as Map<String, dynamic>);
    final (vmB, _) = await boot(buildModel());
    addTearDown(vmB.shutdown);

    final runtimeB = await restored.restoreRuntime(
      vm: vmB,
      policy: ExecutionPolicy.unlimited,
      scheduler: BasicVasterScheduler(taskQueue: PriorityTaskQueue()),
    );
    final finalState = await restored.resumeWith(
      runtimeB,
      respond: HumanInteractionResponse.approve(requestId: 'launch_gate'),
    );

    expect(finalState.status, RuntimeStatus.halted,
        reason: 'error: ${finalState.errorDetails}');
    expect(runtimeB.phase, isA<PhaseHalted>());

    // The launch happened with pre-suspension dataflow intact.
    final launch = await vmB.fileSystemManager
        .resolveFileSystem('/workspace/LAUNCH.txt')
        .readText('/workspace/LAUNCH.txt');
    expect(launch, contains('LAUNCHED orion'));
    expect(launch, contains('GO'),
        reason: 'the extracted verdict crossed the process boundary');
    expect('${finalState.registers['final_verdict']}', 'shipped');
    expect('${finalState.registers['inbox']}', contains('orion'),
        reason: 'actor-message dataflow from before the suspension');

    // Pre-suspension work products crossed too.
    expect(
        await vmB.fileSystemManager
            .resolveFileSystem('/workspace/notes/kickoff.txt')
            .readText('/workspace/notes/kickoff.txt'),
        contains('war room open'));
  });

  test('a tape-driven run checkpoints and resumes identically', () async {
    final program = compiler.compile(warRoom());

    // Record the pre-gate model traffic once.
    final tape = ModelTape();
    final (vmRec, runtimeRec) = await boot(
        RecordingVasterModel(inner: buildModel(), tape: tape));
    final recPaused = await runtimeRec.executeProgram(program);
    expect(recPaused.status, RuntimeStatus.pausedForHuman);
    await vmRec.shutdown();
    expect(tape.entries, isNotEmpty);

    // Replay-driven run to the gate: zero live model calls.
    final (vmA, runtimeA) = await boot(
        ReplayVasterModel(tape: ModelTape.fromJson(tape.toJson())));
    final paused = await runtimeA.executeProgram(program);
    expect(paused.status, RuntimeStatus.pausedForHuman,
        reason: 'error: ${paused.errorDetails}');
    final json = jsonEncode(MachineCheckpoint.capture(
            runtime: runtimeA, vm: vmA, program: program)
        .toJson());
    await vmA.shutdown();

    // Resume the replay-recorded machine in a fresh VM (also tape-backed —
    // record on one backend, resume on another is the durable promise).
    final (vmB, _) = await boot(
        ReplayVasterModel(tape: ModelTape.fromJson(tape.toJson())));
    addTearDown(vmB.shutdown);
    final finalState = await MachineCheckpoint.fromJson(
            jsonDecode(json) as Map<String, dynamic>)
        .resume(
      vm: vmB,
      policy: ExecutionPolicy.unlimited,
      scheduler: BasicVasterScheduler(taskQueue: PriorityTaskQueue()),
      respond: HumanInteractionResponse.approve(requestId: 'launch_gate'),
    );

    expect(finalState.status, RuntimeStatus.halted,
        reason: 'error: ${finalState.errorDetails}');
    expect('${finalState.registers['final_verdict']}', 'shipped');
    final launch = await vmB.fileSystemManager
        .resolveFileSystem('/workspace/LAUNCH.txt')
        .readText('/workspace/LAUNCH.txt');
    expect(launch, contains('LAUNCHED orion'));
  });
}
