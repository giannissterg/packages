import 'dart:convert';

import 'package:test/test.dart';
import 'package:vaster_checkpoint/vaster_checkpoint.dart';
import 'package:vaster_continuation/vaster_continuation.dart';
import 'package:vaster_model_fake/vaster_model_fake.dart';
import 'package:vaster_vm/vaster_vm.dart';

/// Kill-safety: a paused pipeline survives total process amnesia.
///
/// The program is hand-assembled ISA (Rule 1 — no compiler frontend in
/// runtime-side tests): prompt → session work → subroutine call containing a
/// HITL gate → post-return file write. It runs to the gate in VM #1, is
/// captured to JSON, and every live object is discarded; VM #2 restores from
/// the JSON string alone and resumes with an approval.
void main() {
  /// A program whose resume exercises registers, the call stack (paused
  /// INSIDE a subroutine), session history, context regions, memory VFS,
  /// quota meters, and the pending HITL request at once.
  VasterProgram buildProgram() => VasterProgram(
        programName: 'durable_probe',
        instructions: [
          SetQuotaOp(
              quota: ResourceQuota(maxTokenBudget: 100000)), // pc 0
          const AddContextOp(
            // pc 1
            regionId: 'brief',
            label: 'the brief',
            text: 'Resume me faithfully.',
            pinned: true,
          ),
          const CreateSessionOp(sessionId: 'sess_main'), // pc 2
          const SetSessionOp(sessionId: 'sess_main'), // pc 3
          const PromptOp(
              promptText: 'first turn before suspension',
              outputVar: 'pre'), // pc 4
          const WriteFileOp(
              vfsPath: '/mem/pre.txt', content: 'written before'), // pc 5
          const CallOp(targetPc: 9, functionName: 'gated'), // pc 6
          const WriteFileOp(
              vfsPath: '/mem/post.txt',
              content: 'after return: ${'\${answer}'}'), // pc 7
          const HaltOp(), // pc 8
          // ── subroutine 'gated' ──
          YieldHumanInteractionOp(
            // pc 9
            request: const HumanInteractionRequest(
              requestId: 'gate',
              type: HumanInteractionType.approval,
              prompt: 'continue?',
              options: ['approve', 'reject'],
              outputVar: 'answer',
            ),
          ),
          const PromptOp(
              promptText: 'turn after resume, same session',
              outputVar: 'post'), // pc 10
          const ReturnSubroutineOp(), // pc 11
        ],
      );

  test('capture at a HITL pause inside a subroutine, resume in a FRESH VM',
      () async {
    // ── Act I: original process ──
    final vmA = await VasterVMEngine.bootstrap(
        config: VMConfig(defaultModel: FakeVasterModel()));
    final runtimeA = VasterRuntime(
      vm: vmA,
      policy: ExecutionPolicy.unlimited,
      budget: ExecutionBudget.unlimited(),
      scheduler: BasicVasterScheduler(taskQueue: PriorityTaskQueue()),
    );
    final program = buildProgram();

    final paused = await runtimeA.executeProgram(program);
    expect(paused.status, RuntimeStatus.pausedForHuman,
        reason: 'error: ${paused.errorDetails}');
    expect(runtimeA.callStackSnapshot, isNotEmpty,
        reason: 'paused inside the subroutine');

    final checkpointJson = jsonEncode(MachineCheckpoint.capture(
      runtime: runtimeA,
      vm: vmA,
      program: program,
    ).toJson());

    final tokensAtCapture = runtimeA.quotaConsumedTokens;
    expect(tokensAtCapture, greaterThan(0));

    // ── Total amnesia: the original process "dies" ──
    await vmA.shutdown();

    // ── Act II: a fresh process, nothing but the JSON string ──
    final restored = MachineCheckpoint.fromJson(
        jsonDecode(checkpointJson) as Map<String, dynamic>);
    final vmB = await VasterVMEngine.bootstrap(
        config: VMConfig(defaultModel: FakeVasterModel()));
    addTearDown(vmB.shutdown);

    final finalState = await restored.resume(
      vm: vmB,
      policy: ExecutionPolicy.unlimited,
      scheduler: BasicVasterScheduler(taskQueue: PriorityTaskQueue()),
      respond: HumanInteractionResponse.approve(requestId: 'gate'),
    );

    expect(finalState.status, RuntimeStatus.halted,
        reason: 'error: ${finalState.errorDetails}');

    // Registers: pre-suspension value survived; post-resume values exist;
    // the RET landed back in the caller (post.txt written after return).
    expect('${finalState.registers['pre']}', isNotEmpty);
    expect('${finalState.registers['post']}', isNotEmpty);
    expect(finalState.registers['answer_status'], isTrue);

    Future<String> read(String path) =>
        vmB.fileSystemManager.resolveFileSystem(path).readText(path);
    expect(await read('/mem/pre.txt'), 'written before',
        reason: 'memory VFS files must survive the process boundary');
    expect(await read('/mem/post.txt'), contains('after return'),
        reason: 'the call stack must survive: RET runs after resume');

    // Session history continued, not restarted: the pre-suspension turn is
    // in the same session the post-resume prompt used.
    final session = vmB.sessionManager.getSession('sess_main');
    expect(session, isNotNull);
    expect(
        session!.history.map((m) => m.text),
        containsAll(
            ['first turn before suspension', 'turn after resume, same session']),
        reason: 'one continuous conversation across the suspension');

    // Context heap restored, pinned bit intact.
    final region = vmB.contextManager.getRegion('brief');
    expect(region, isNotNull);
    expect(region!.isPinned, isTrue);
  });

  test('quota meters continue from, not restart at, captured values',
      () async {
    final vmA = await VasterVMEngine.bootstrap(
        config: VMConfig(defaultModel: FakeVasterModel()));
    final runtimeA = VasterRuntime(
      vm: vmA,
      policy: ExecutionPolicy.unlimited,
      budget: ExecutionBudget.unlimited(),
      scheduler: BasicVasterScheduler(taskQueue: PriorityTaskQueue()),
    );
    final program = buildProgram();
    await runtimeA.executeProgram(program);
    final captured = MachineCheckpoint.capture(
        runtime: runtimeA, vm: vmA, program: program);
    final tokensAtCapture = captured.quotaConsumedTokens;
    expect(tokensAtCapture, greaterThan(0));
    await vmA.shutdown();

    final vmB = await VasterVMEngine.bootstrap(
        config: VMConfig(defaultModel: FakeVasterModel()));
    addTearDown(vmB.shutdown);
    final runtimeB = await MachineCheckpoint.fromJson(
            jsonDecode(jsonEncode(captured.toJson())) as Map<String, dynamic>)
        .restoreRuntime(
      vm: vmB,
      policy: ExecutionPolicy.unlimited,
      scheduler: BasicVasterScheduler(taskQueue: PriorityTaskQueue()),
    );

    expect(runtimeB.quotaConsumedTokens, tokensAtCapture,
        reason: 'no free ride: consumption resumes where it stood');
    expect(runtimeB.activeQuota.maxTokenBudget, 100000,
        reason: 'the program-declared quota itself is restored');
    expect(runtimeB.budget.consumedTokens, captured.budgetConsumedTokens,
        reason: 'host budget continues too');
  });

  test('checkpoint JSON round-trips and rejects unknown format versions', () {
    final vmless = MachineCheckpoint(
      programVbcBase64: base64Encode(
          const VasterProgram(programName: 'p', instructions: [HaltOp()])
              .toBytes()),
      continuation: VasterContinuation(
        continuationId: 'c1',
        programName: 'p',
        resumePc: 0,
        registers: const {'x': 1},
      ),
      sessions: const [],
      contextRegions: const [],
      memoryMounts: const {},
      quota: ResourceQuota.unlimited,
      quotaConsumedTokens: 5,
      quotaConsumedCost: 0.1,
      quotaConsumedToolCalls: 2,
      budgetConsumedTokens: 9,
      budgetConsumedCost: 0.2,
      budgetConsumedDuration: const Duration(seconds: 3),
      capturedAt: DateTime.utc(2026, 8, 5),
    );

    final restored = MachineCheckpoint.fromJson(
        jsonDecode(jsonEncode(vmless.toJson())) as Map<String, dynamic>);
    expect(restored.continuation.registers['x'], 1);
    expect(restored.quotaConsumedTokens, 5);
    expect(restored.budgetConsumedDuration, const Duration(seconds: 3));
    expect(restored.decodeProgram().programName, 'p');

    final tampered = vmless.toJson()..['formatVersion'] = 99;
    expect(() => MachineCheckpoint.fromJson(tampered),
        throwsA(isA<FormatException>()));
  });
}
