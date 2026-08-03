import 'dart:convert';

import 'package:vaster_continuation/vaster_continuation.dart';
import 'package:vaster_continuation_manager/vaster_continuation_manager.dart';
import 'package:vaster_model_fake/vaster_model_fake.dart';
import 'package:vaster_vm/vaster_vm.dart';

void main() async {
  print('================================================================');
  print('       Vaster Continuation & Snapshot Manager Demo              ');
  print('================================================================\n');

  // 1. Bootstrap VM & Continuation Manager
  final vm = await VasterVMEngine.bootstrap(config: VMConfig(defaultModel: FakeVasterModel()));
  final continuationManager = BasicContinuationManager(store: MemoryContinuationStore());

  // 2. Build program manually with low-level ISA instructions:
  //    0: WriteFileOp('/mem/build.log', 'Build succeeded.')
  //    1: BeginTransactionOp
  //    2: YieldHumanInteractionOp(deploy_to_prod)
  //    3: JumpIfOp('deploy_to_prod_status', targetPc: 5)
  //    4: JumpOp(targetPc: 6)          ← skip reject (empty)
  //    5: WriteFileOp('/mem/release.log', 'v1.2.0 Live in Prod.')  ← approve branch
  //    6: CommitOp
  //    7: HaltOp
  final program = VasterProgram(
    programName: 'production_deployment_pipeline',
    instructions: [
      const WriteFileOp(vfsPath: '/mem/build.log', content: 'Build succeeded.'),
      const BeginTransactionOp(),
      YieldHumanInteractionOp(
        request: HumanInteractionRequest(
          requestId: 'deploy_to_prod',
          type: HumanInteractionType.approval,
          prompt: 'Deploy release v1.2.0 to production?',
          options: const ['approve', 'reject'],
          outputVar: 'deploy_to_prod',
        ),
      ),
      const JumpIfOp(conditionVar: 'deploy_to_prod_status', targetPc: 5),
      const JumpOp(targetPc: 6),
      const WriteFileOp(vfsPath: '/mem/release.log', content: 'v1.2.0 Live in Prod.'),
      const CommitOp(),
      const HaltOp(),
    ],
  );

  // 3. Start execution
  print('▶ 1. Starting execution on Server Instance #1...');
  final runtime1 = VasterRuntime(
    vm: vm,
    policy: ExecutionPolicy.unlimited,
    budget: ExecutionBudget.unlimited(),
    scheduler: BasicVasterScheduler(taskQueue: PriorityTaskQueue()),
  );
  final state1 = await runtime1.executeProgram(program);
  print('   Status: ${state1.status.name} (PC: ${state1.pc})\n');

  // 4. Capture continuation snapshot and serialize to JSON
  print('💾 2. Capturing VasterContinuation snapshot...');
  final snapshot = await continuationManager.capture(runtime1, program.programName);
  final jsonString = const JsonEncoder.withIndent('  ').convert(snapshot.toJson());
  print('   Snapshot JSON Payload:');
  print('$jsonString\n');

  // 5. Simulate Server Restart / Restore on Server Instance #2
  print('🔄 3. Restoring snapshot on Server Instance #2 & approving deployment...');
  final restoredSnapshot = VasterContinuation.fromJson(jsonDecode(jsonString));
  final runtime2 = VasterRuntime(
    vm: vm,
    policy: ExecutionPolicy.unlimited,
    budget: ExecutionBudget.unlimited(),
    scheduler: BasicVasterScheduler(taskQueue: PriorityTaskQueue()),
  );

  final finalState = await continuationManager.restoreAndResume(
    runtime2,
    restoredSnapshot,
    program,
    humanResponse: HumanInteractionResponse.approve(requestId: 'deploy_to_prod'),
  );

  print('   Status: ${finalState.status.name}');
  final log = await vm.fileSystemManager
      .resolveFileSystem('/mem/release.log')
      .readText('/mem/release.log');
  print('   Release Log: "$log"');
  print('✅ Pipeline completed successfully!');
}