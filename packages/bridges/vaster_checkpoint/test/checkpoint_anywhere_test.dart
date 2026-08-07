import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:vaster_checkpoint/vaster_checkpoint.dart';
import 'package:vaster_machine_state/vaster_machine_state.dart';
import 'package:vaster_model_fake/vaster_model_fake.dart';
import 'package:vaster_vm/vaster_vm.dart';

/// THE enforcement tests: forgetting machine state must be impossible.
///
/// 1. Checkpoint-anywhere: capture at EVERY instruction boundary of a
///    state-heavy program, restore each into a completely fresh VM, run to
///    completion — the final state must equal the uninterrupted run's. A
///    loose field that affects execution but escapes the snapshot fails
///    this behaviorally; no reflection needed.
/// 2. Round-trip completeness: capture → restore → capture is deep-equal.
/// 3. Inbox survival: the hole this review found — a message sent before
///    suspension is popped after resume.
void main() {
  /// Exercises every state-mutating opcode family: quota, context, session,
  /// model context (with a fallback chain — REL-P3), toolset, error
  /// handlers, subroutine frames, registers, messaging — with post-state
  /// instructions that DEPEND on each piece, so lost state changes the
  /// outcome. The PromptOp only succeeds through the chain's fallback: a
  /// restore that drops `activeModelFallbacks` retries the dead primary
  /// alone and takes a different path.
  VasterProgram stateHeavyProgram() => VasterProgram(
        programName: 'state_gauntlet',
        resultBinding: 'final_out',
        instructions: [
          SetQuotaOp(quota: ResourceQuota(maxTokenBudget: 500000)), // 0
          const AddContextOp(regionId: 'ctx', label: 'ctx', text: 'ground truth', pinned: true), // 1
          const CreateSessionOp(sessionId: 'sess_g'), // 2
          const SetSessionOp(sessionId: 'sess_g'), // 3
          RegisterToolSetOp(tools: const [
            ToolDefinition(name: 'noop', description: 'n', parametersSchema: {}),
          ]), // 4
          const SelectModelOp(
              descriptor: ModelDescriptor(provider: 'gauntlet_down', modelId: 'p'),
              fallbacks: [
                ModelDescriptor(provider: 'gauntlet_up', modelId: 'f'),
              ]), // 5
          const MountFsOp(mountPrefix: '/mem'), // 6
          const WriteFileOp(vfsPath: '/mem/tx.txt', content: 'clean'), // 7
          const PushEffectScopeOp(), // 8 (open across every capture below)
          const PushErrorHandlerOp(targetPc: 18, errorVar: 'err'), // 9
          const SendMessageOp(senderId: 'a', recipientId: 'b', payload: {'note': 'durable'}),
          // 10
          const PromptOp(promptText: 'turn one', outputVar: 'r1'), // 11
          const CallOp(targetPc: 20, functionName: 'sub'), // 12
          const PopMessageOp(agentId: 'b', outputVar: 'inbox_out'), // 13
          // A transaction OPEN at the following capture boundaries — its
          // rollback is load-bearing: the boom below must restore
          // /mem/tx.txt to 'clean', so a restore that drops the open
          // frame visibly changes final_out to contain 'dirty'.
          const BeginTransactionOp(), // 14
          const WriteFileOp(vfsPath: '/mem/tx.txt', content: 'dirty'), // 15
          const ReadFileOp(vfsPath: '/not_mounted/boom.txt', outputVar: 'never'), // 16
          const HaltOp(), // 17 (skipped: handler jumps to 18)
          const ReadFileOp(vfsPath: '/mem/tx.txt', outputVar: 'tx_state'), // 18 (catch)
          const ConcatRegisterOp(
              targetVar: 'final_out', sourceVars: ['r1', 'sub_out', 'inbox_out', 'tx_state']),
          // 19 + halt below
          const SetRegisterOp(registerName: 'sub_out', value: 'sub_ran'), // 20
          const ReturnSubroutineOp(), // 21
        ],
      );

  Future<(VasterVMEngine, VasterRuntime)> boot() async {
    final vm = await VasterVMEngine.bootstrap(config: VMConfig(defaultModel: FakeVasterModel()));
    // The gauntlet's model chain: a dead primary and a live fallback —
    // registered identically in every fresh VM so only MACHINE state
    // decides which one serves.
    vm.modelRegistry.registerModel(
      const ModelDescriptor(provider: 'gauntlet_down', modelId: 'p'),
      FakeVasterModel(modelName: 'gauntlet-down', handler: (req) => throw StateError('API error 500 down')),
    );
    vm.modelRegistry.registerModel(
      const ModelDescriptor(provider: 'gauntlet_up', modelId: 'f'),
      FakeVasterModel(modelName: 'gauntlet-up', defaultResponseText: 'served by fallback'),
    );
    final runtime = VasterRuntime(
      vm: vm,
      policy: ExecutionPolicy.unlimited,
      budget: ExecutionBudget.unlimited(),
      scheduler: BasicVasterScheduler(taskQueue: PriorityTaskQueue()),
    );
    return (vm, runtime);
  }

  test('CHECKPOINT ANYWHERE: every boundary restores to the same outcome', () async {
    final program = stateHeavyProgram();

    // Reference: the uninterrupted run.
    final (vmRef, runtimeRef) = await boot();
    final reference = await runtimeRef.executeProgram(program);
    // The program is built to end via the error handler path.
    expect(reference.status, RuntimeStatus.halted, reason: 'reference error: ${reference.errorDetails}');
    final referenceOut = '${reference.registers['final_out']}';
    expect(referenceOut, isNotEmpty);
    expect(referenceOut, contains('served by fallback'),
        reason: 'the gauntlet prompt must be served THROUGH the chain — '
            'otherwise the fallback state is never load-bearing');
    expect(referenceOut, contains('clean'),
        reason: 'the abandoned transaction must roll back on the handler '
            'path — final_out carries the restored file content');
    expect(referenceOut, isNot(contains('dirty')),
        reason: 'a partial in-transaction write must never survive the '
            'catch');
    await vmRef.shutdown();

    // Capture a checkpoint at every instruction BOUNDARY — stepping one
    // instruction at a time so the machine is at rest when captured. (A
    // capture inside stepObserver is mid-transition: the pc has not advanced
    // yet, so resuming would RE-EXECUTE a non-idempotent instruction — the
    // first draft of this test proved that by double-popping a message.)
    final (vmA, runtimeA) = await boot();
    final checkpoints = <int, String>{};
    var state = await runtimeA.executeStep(program, stepCount: 1);
    var guard = 0;
    while (state.status == RuntimeStatus.running && guard++ < 100) {
      checkpoints[state.pc] = jsonEncode(MachineCheckpoint.capture(
        runtime: runtimeA,
        vm: vmA,
        program: program,
      ).toJson());
      state = await runtimeA.executeStep(program, stepCount: 1);
    }
    expect(state.status, RuntimeStatus.halted, reason: 'stepped error: ${state.errorDetails}');
    await vmA.shutdown();
    expect(checkpoints.length, greaterThan(8), reason: 'the gauntlet must actually execute its breadth');

    // Every checkpoint resumes in a FRESH VM to the same final output.
    for (final entry in checkpoints.entries) {
      final restored = MachineCheckpoint.fromJson(jsonDecode(entry.value) as Map<String, dynamic>);
      final (vmB, _) = await boot();
      final resumed = await restored.resume(
        vm: vmB,
        policy: ExecutionPolicy.unlimited,
        scheduler: BasicVasterScheduler(taskQueue: PriorityTaskQueue()),
      );
      expect(resumed.status, RuntimeStatus.halted,
          reason: 'resume from pc ${entry.key} failed: '
              '${resumed.errorDetails}');
      expect('${resumed.registers['final_out']}', referenceOut,
          reason: 'state lost when checkpointing after pc ${entry.key} — '
              'some machine state escaped the snapshot');
      await vmB.shutdown();
    }
  });

  test('round-trip completeness: capture → restore → capture is deep-equal', () async {
    final program = stateHeavyProgram();
    final (vmA, runtimeA) = await boot();
    // Stop mid-gauntlet (after the subroutine call is on the stack).
    MachineSnapshot? mid;
    runtimeA.stepObserver = (pc, _, __) {
      if (pc == 8) mid = runtimeA.captureSnapshot();
    };
    await runtimeA.executeProgram(program);
    expect(mid, isNotNull);
    await vmA.shutdown();

    final (vmB, runtimeB) = await boot();
    runtimeB.restoreSnapshot(
        MachineSnapshot.fromJson(jsonDecode(jsonEncode(mid!.toJson())) as Map<String, dynamic>));
    final recaptured = runtimeB.captureSnapshot();
    expect(jsonEncode(recaptured.toJson()), jsonEncode(mid!.toJson()),
        reason: 'a restore must reproduce the machine exactly');
    await vmB.shutdown();
  });

  test('INBOX SURVIVAL: a message sent before suspension pops after resume', () async {
    final program = VasterProgram(
      programName: 'durable_mail',
      instructions: [
        const SendMessageOp(senderId: 'a', recipientId: 'b', payload: {'note': 'survive me'}),
        YieldHumanInteractionOp(
          request: const HumanInteractionRequest(
            requestId: 'gate',
            type: HumanInteractionType.approval,
            prompt: 'continue?',
            outputVar: 'g',
          ),
        ),
        const PopMessageOp(agentId: 'b', outputVar: 'delivered'),
        const HaltOp(),
      ],
    );

    final (vmA, runtimeA) = await boot();
    final paused = await runtimeA.executeProgram(program);
    expect(paused.status, RuntimeStatus.pausedForHuman);
    final json = jsonEncode(MachineCheckpoint.capture(runtime: runtimeA, vm: vmA, program: program).toJson());
    await vmA.shutdown();

    final (vmB, _) = await boot();
    final resumed = await MachineCheckpoint.fromJson(jsonDecode(json) as Map<String, dynamic>).resume(
      vm: vmB,
      policy: ExecutionPolicy.unlimited,
      scheduler: BasicVasterScheduler(taskQueue: PriorityTaskQueue()),
      respond: HumanInteractionResponse.approve(requestId: 'gate'),
    );
    expect(resumed.status, RuntimeStatus.halted, reason: 'error: ${resumed.errorDetails}');
    expect('${resumed.registers['delivered']}', contains('survive me'),
        reason: 'undelivered actor messages are durable state');
    await vmB.shutdown();
  });
  test(
      'DISK MOUNT SURVIVAL: a pre-suspension MountFsOp is re-established '
      'on resume', () async {
    final diskDir = Directory.systemTemp.createTempSync('vaster_disk_mount_');
    addTearDown(() => diskDir.deleteSync(recursive: true));

    final program = VasterProgram(
      programName: 'durable_disk',
      instructions: [
        MountFsOp(mountPrefix: '/out', diskPath: diskDir.path), // 0
        YieldHumanInteractionOp(
          request: const HumanInteractionRequest(
            requestId: 'gate',
            type: HumanInteractionType.approval,
            prompt: 'continue?',
            outputVar: 'g',
          ),
        ), // 1
        const WriteFileOp(vfsPath: '/out/artifact.txt', content: 'post-resume'), // 2
        const HaltOp(), // 3
      ],
    );

    final (vmA, runtimeA) = await boot();
    final paused = await runtimeA.executeProgram(program);
    expect(paused.status, RuntimeStatus.pausedForHuman);
    final json = jsonEncode(MachineCheckpoint.capture(runtime: runtimeA, vm: vmA, program: program).toJson());
    await vmA.shutdown();

    // The fresh VM never executed the MountFsOp (it is pre-gate) — the
    // checkpoint's mount table must re-establish it. Found by the first
    // real-backend prove-it run: without this, the resume traps resolving
    // the prefix.
    final (vmB, _) = await boot();
    addTearDown(vmB.shutdown);
    final resumed = await MachineCheckpoint.fromJson(jsonDecode(json) as Map<String, dynamic>).resume(
      vm: vmB,
      policy: ExecutionPolicy.unlimited,
      scheduler: BasicVasterScheduler(taskQueue: PriorityTaskQueue()),
      respond: HumanInteractionResponse.approve(requestId: 'gate'),
    );
    expect(resumed.status, RuntimeStatus.halted, reason: 'error: ${resumed.errorDetails}');
    expect(File('${diskDir.path}/artifact.txt').readAsStringSync(), 'post-resume',
        reason: 'the post-resume write must land on the REAL disk mount');
  });
}
