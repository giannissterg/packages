import 'package:test/test.dart';
import 'package:vaster_continuation/vaster_continuation.dart';
import 'package:vaster_continuation_manager/vaster_continuation_manager.dart';
import 'package:vaster_domain/vaster_domain.dart';
import 'package:vaster_model_fake/vaster_model_fake.dart';
import 'package:vaster_vm/vaster_vm.dart';

void main() {
  group('VasterContinuation Entity Model', () {
    late VasterVirtualMachine vm;
    late ContinuationManager continuationManager;

    setUp(() async {
      vm = await VasterVMEngine.bootstrap(config: VMConfig(defaultModel: FakeVasterModel()));
      continuationManager = BasicContinuationManager(store: MemoryContinuationStore());
    });

    test(
      'captures and restores execution continuation snapshot using ContinuationManager',
      () async {
        // Build program manually with low-level ISA instructions:
        // 0: WriteFileOp('/mem/step1.txt', 'step_1_done')
        // 1: BeginTransactionOp
        // 2: YieldHumanInteractionOp(approval_pkg_001)
        // 3: JumpIfOp('approval_pkg_001_status', targetPc: 5)
        // 4: JumpOp(targetPc: 6)          ← skip reject (empty)
        // 5: WriteFileOp('/mem/step2.txt', 'step_2_done')  ← approve branch
        // 6: CommitOp
        // 7: HaltOp
        final program = VasterProgram(
          programName: 'continuation_pkg_pipeline',
          instructions: [
            const WriteFileOp(vfsPath: '/mem/step1.txt', content: 'step_1_done'),
            const BeginTransactionOp(),
            YieldHumanInteractionOp(
              request: HumanInteractionRequest(
                requestId: 'approval_pkg_001',
                type: HumanInteractionType.approval,
                prompt: 'Approve continuation package test?',
                options: const ['approve', 'reject'],
                outputVar: 'approval_pkg_001',
              ),
            ),
            const JumpIfOp(conditionVar: 'approval_pkg_001_status', targetPc: 5),
            const JumpOp(targetPc: 6),
            const WriteFileOp(vfsPath: '/mem/step2.txt', content: 'step_2_done'),
            const CommitOp(),
            const HaltOp(),
          ],
        );

        // 1. Execute program until HITL yield
        final runtime1 = VasterRuntime(
          vm: vm,
          policy: ExecutionPolicy.unlimited,
          budget: ExecutionBudget.unlimited(),
          scheduler: BasicVasterScheduler(taskQueue: PriorityTaskQueue()),
        );
        final state1 = await runtime1.executeProgram(program);
        expect(state1.status, equals(RuntimeStatus.pausedForHuman));

        // 2. Capture continuation snapshot using dedicated ContinuationManager
        final snapshot = await continuationManager.capture(runtime1, program.programName);
        final jsonMap = snapshot.toJson();

        // 3. Reconstruct snapshot from JSON
        final restoredSnapshot = VasterContinuation.fromJson(jsonMap);
        expect(restoredSnapshot.programName, equals('continuation_pkg_pipeline'));

        // 4. Restore execution on a fresh runtime instance
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
          humanResponse: HumanInteractionResponse.approve(requestId: 'approval_pkg_001'),
        );

        expect(state2.status, equals(RuntimeStatus.halted));
        final step2Content = await vm.fileSystemManager
            .resolveFileSystem('/mem/step2.txt')
            .readText('/mem/step2.txt');
        expect(step2Content, equals('step_2_done'));
      },
    );
  });
}