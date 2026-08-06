import 'package:test/test.dart';
import 'package:vaster_continuation/vaster_continuation.dart';
import 'package:vaster_continuation_manager/vaster_continuation_manager.dart';
import 'package:vaster_model_fake/vaster_model_fake.dart';
import 'package:vaster_vm/vaster_vm.dart';

/// Helper: builds a VasterProgram that mimics an ApprovalGate with
/// approve/reject branches — without depending on vaster_ast or vaster_compiler.
///
/// Layout (no reject instructions):
/// ```
/// 0: BeginTransactionOp
/// 1: YieldHumanInteractionOp(request)
/// 2: JumpIfOp(conditionVar: '${requestId}_status', targetPc: <approveStart>)
/// 3: <reject instructions...>
///   : JumpOp(targetPc: <afterApprove>)
///   : <approve instructions...>
///   : CommitOp
///   : HaltOp
/// ```
VasterProgram _approvalGateProgram({
  required String programName,
  required String requestId,
  required String prompt,
  required List<VasterInstruction> onApprove,
  List<VasterInstruction> onReject = const [],
}) {
  final rejectLen = onReject.length;
  final approveLen = onApprove.length;

  final approveStart = 3 + rejectLen + 1;
  final afterApprove = approveStart + approveLen;

  final instructions = <VasterInstruction>[
    const BeginTransactionOp(),
    YieldHumanInteractionOp(
      request: HumanInteractionRequest(
        requestId: requestId,
        type: HumanInteractionType.approval,
        prompt: prompt,
        options: const ['approve', 'reject'],
        outputVar: requestId,
      ),
    ),
    JumpIfOp(conditionVar: '${requestId}_status', targetPc: approveStart),
    ...onReject,
    JumpOp(targetPc: afterApprove),
    ...onApprove,
    const CommitOp(),
    const HaltOp(),
  ];

  return VasterProgram(programName: programName, instructions: instructions);
}

void main() {
  group('Human-in-the-Loop (HITL) Runtime Interactivity', () {
    late VasterVirtualMachine vm;

    setUp(() async {
      vm = await VasterVMEngine.bootstrap(config: VMConfig(defaultModel: FakeVasterModel()));
    });

    test('yields execution and pauses at YieldHumanInteractionOp', () async {
      const request = HumanInteractionRequest(
        requestId: 'req_qa_01',
        type: HumanInteractionType.approval,
        prompt: 'Approve deployment to production?',
        options: ['approve', 'reject'],
        outputVar: 'approval_res',
      );

      final program = const VasterProgram(
        programName: 'hitl_test',
        instructions: [
          YieldHumanInteractionOp(request: request),
          SetRegisterOp(registerName: 'after_pause', value: 'resumed'),
          HaltOp(),
        ],
      );

      final runtime = VasterRuntime(
        vm: vm,
        policy: ExecutionPolicy.unlimited,
        budget: ExecutionBudget.unlimited(),
        scheduler: BasicVasterScheduler(taskQueue: PriorityTaskQueue()),
      );

      final initialState = await runtime.executeProgram(program);

      expect(initialState.status, equals(RuntimeStatus.pausedForHuman));
      expect(runtime.pendingHumanRequest?.requestId, equals('req_qa_01'));

      // Resumes using the whole-machine snapshot (captures registers, call
      // stack, HITL pending request, ambient context, and quota in one fold).
      final snapshot = runtime.captureSnapshot();
      final resumedState = await runtime.restoreAndResume(
        snapshot,
        program,
        humanResponse: HumanInteractionResponse.approve(
            requestId: 'req_qa_01', comment: 'LGTM!'),
      );

      expect(resumedState.status, equals(RuntimeStatus.halted));
      expect(resumedState.registers['approval_res'], equals('LGTM!'));
      expect(resumedState.registers['approval_res_status'], isTrue);
      expect(resumedState.registers['after_pause'], equals('resumed'));
    });

    test('HumanApprovalComponent branches based on human response', () async {
      final program = _approvalGateProgram(
        programName: 'approval_pipeline',
        requestId: 'prod_deploy',
        prompt: 'Approve deployment?',
        onApprove: const [WriteFileOp(vfsPath: '/mem/deploy.txt', content: 'DEPLOYED')],
        onReject: const [WriteFileOp(vfsPath: '/mem/deploy.txt', content: 'REJECTED')],
      );

      final runtime = VasterRuntime(
        vm: vm,
        policy: ExecutionPolicy.unlimited,
        budget: ExecutionBudget.unlimited(),
        scheduler: BasicVasterScheduler(taskQueue: PriorityTaskQueue()),
      );

      // 1. Initial run yields for approval
      final state1 = await runtime.executeProgram(program);
      expect(state1.status, equals(RuntimeStatus.pausedForHuman));

      // 2. User approves
      final state2 = await runtime.resumeWithHumanResponse(
        HumanInteractionResponse.approve(requestId: 'prod_deploy'),
      );

      expect(state2.status, equals(RuntimeStatus.halted));

      // Read file content from VFS
      final content = await vm.fileSystemManager
          .resolveFileSystem('/mem/deploy.txt')
          .readText('/mem/deploy.txt');
      expect(content, equals('DEPLOYED'));
    });

    test('HumanApprovalComponent executes onReject branch when user rejects', () async {
      final program = _approvalGateProgram(
        programName: 'rejection_pipeline',
        requestId: 'staging_deploy',
        prompt: 'Approve deployment to staging?',
        onApprove: const [WriteFileOp(vfsPath: '/mem/staging.txt', content: 'APPROVED_STAGING')],
        onReject: const [WriteFileOp(vfsPath: '/mem/staging.txt', content: 'REJECTED_STAGING')],
      );

      final runtime = VasterRuntime(
        vm: vm,
        policy: ExecutionPolicy.unlimited,
        budget: ExecutionBudget.unlimited(),
        scheduler: BasicVasterScheduler(taskQueue: PriorityTaskQueue()),
      );

      // 1. Initial run yields for approval
      final state1 = await runtime.executeProgram(program);
      expect(state1.status, equals(RuntimeStatus.pausedForHuman));
      expect(runtime.pendingHumanRequest?.requestId, equals('staging_deploy'));

      // 2. User rejects with feedback comment
      final state2 = await runtime.resumeWithHumanResponse(
        HumanInteractionResponse.reject(
          requestId: 'staging_deploy',
          reason: 'Security review pending',
        ),
      );

      expect(state2.status, equals(RuntimeStatus.halted));
      expect(state2.registers['staging_deploy_status'], isFalse);
      expect(state2.registers['staging_deploy'], equals('Security review pending'));

      // Read file content from VFS
      final content = await vm.fileSystemManager
          .resolveFileSystem('/mem/staging.txt')
          .readText('/mem/staging.txt');
      expect(content, equals('REJECTED_STAGING'));
    });

    test('supports full VasterContinuation snapshot serialization & restoration via ContinuationManager', () async {
      final continuationManager = BasicContinuationManager(store: MemoryContinuationStore());

      // Build program manually with low-level ISA instructions:
      // 0: WriteFileOp('/mem/before.txt', 'hello')
      // 1: BeginTransactionOp
      // 2: YieldHumanInteractionOp(approval_001)
      // 3: JumpIfOp('approval_001_status', targetPc: 5)
      // 4: JumpOp(targetPc: 6)          ← skip reject (empty)
      // 5: WriteFileOp('/mem/after.txt', 'world')  ← approve branch
      // 6: CommitOp
      // 7: HaltOp
      final program = VasterProgram(
        programName: 'snapshot_pipeline',
        instructions: [
          const WriteFileOp(vfsPath: '/mem/before.txt', content: 'hello'),
          const BeginTransactionOp(),
          YieldHumanInteractionOp(
            request: HumanInteractionRequest(
              requestId: 'approval_001',
              type: HumanInteractionType.approval,
              prompt: 'Approve continuation snapshot test?',
              options: const ['approve', 'reject'],
              outputVar: 'approval_001',
            ),
          ),
          const JumpIfOp(conditionVar: 'approval_001_status', targetPc: 5),
          const JumpOp(targetPc: 6),
          const WriteFileOp(vfsPath: '/mem/after.txt', content: 'world'),
          const CommitOp(),
          const HaltOp(),
        ],
      );

      // 1. First runtime instance starts program and pauses at HITL node
      final runtime1 = VasterRuntime(
        vm: vm,
        policy: ExecutionPolicy.unlimited,
        budget: ExecutionBudget.unlimited(),
        scheduler: BasicVasterScheduler(taskQueue: PriorityTaskQueue()),
      );
      final state1 = await runtime1.executeProgram(program);
      expect(state1.status, equals(RuntimeStatus.pausedForHuman));

      // 2. Capture VasterContinuation snapshot and serialize to JSON
      final snapshot = await continuationManager.capture(runtime1, program.programName);
      final snapshotJson = snapshot.toJson();

      // 3. Reconstruct VasterContinuation snapshot from JSON (e.g. Server restart)
      final restoredSnapshot = VasterContinuation.fromJson(snapshotJson);
      expect(restoredSnapshot.programName, equals('snapshot_pipeline'));

      // 4. Second runtime instance restores execution from snapshot and finishes program
      final runtime2 = VasterRuntime(
        vm: vm,
        policy: ExecutionPolicy.unlimited,
        budget: ExecutionBudget.unlimited(),
        scheduler: BasicVasterScheduler(taskQueue: PriorityTaskQueue()),
      );
      final state2 = await continuationManager.restoreAndResume(
        runtime2,
        restoredSnapshot,
        program,
        humanResponse: HumanInteractionResponse.approve(requestId: 'approval_001'),
      );

      expect(state2.status, equals(RuntimeStatus.halted));
      final afterContent = await vm.fileSystemManager
          .resolveFileSystem('/mem/after.txt')
          .readText('/mem/after.txt');
      expect(afterContent, equals('world'));
    });

  });
}