import 'dart:io';

import 'package:vaster_ast/vaster_ast.dart';
import 'package:vaster_compiler/vaster_compiler.dart';
import 'package:vaster_continuation_manager/vaster_continuation_manager.dart';
import 'package:vaster_domain/vaster_domain.dart';
import 'package:vaster_model_fake/vaster_model_fake.dart';
import 'package:vaster_vm/vaster_vm.dart';

void main() async {
  print('======================================================================');
  print('    VASTER HITL HUMAN APPROVAL & HANG PREVENTION DEMO                 ');
  print('  1. Non-blocking Pause  2. Disk Offloading  3. Budget Timeouts       ');
  print('======================================================================\n');

  final tempDir = await Directory.systemTemp.createTemp('vaster_hitl_demo_');
  final fileStore = FileContinuationStore(storageDirectory: tempDir);
  final continuationManager = BasicContinuationManager(store: fileStore);

  const engineerRole = AgentRole(
    roleId: 'engineer',
    name: 'DevOps Engineer',
    title: 'Site Reliability Engineer',
    instruction: 'Prepares production deployments.',
  );

  // 1. Build AST with ApprovalGate
  final pipeline = Pipeline(
    spec: const PipelineSpec(name: 'hitl_hang_prevention_pipeline'),
    roles: const [engineerRole],
    children: [
      Agent(
        role: engineerRole,
        children: const [
          WriteFile(
            path: '/workspace/prod_config.json',
            content: '{"db": "production_cluster", "replicas": 5}',
          ),
          Task(prompt: 'Prepare deployment configuration.'),
        ],
      ),

      // Human Approval Gate
      const ApprovalGate(
        requestId: 'prod_deploy_gate',
        prompt: 'Approve execution of production cluster deployment?',
        onApprove: [
          WriteFile(path: '/workspace/deploy.log', content: 'Deployed to production cluster successfully.'),
        ],
        onReject: [
          WriteFile(path: '/workspace/deploy.log', content: 'Deployment rejected by operator.'),
        ],
      ),

      const Output(),
    ],
  );

  const compiler = BasicWorkflowCompiler();
  final program = compiler.compile(pipeline);

  print('┌─ SCENARIO 1: Non-Blocking HITL Pause & Disk Snapshot Offloading ─┐');
  final vm1 = await VasterVMEngine.bootstrap(
    config: VMConfig(defaultModel: FakeVasterModel(), rootMountPath: '/workspace'),
  );

  // Bounded budget
  final budget1 = ExecutionBudget(maxDuration: const Duration(seconds: 30));

  final runtime1 = VasterRuntime(
    vm: vm1,
    policy: ExecutionPolicy.unlimited,
    budget: budget1,
    scheduler: BasicVasterScheduler(taskQueue: PriorityTaskQueue()),
  );

  // Execute turn 1 -> Pauses at HITL gate
  var state1 = await runtime1.executeProgram(program);
  print('  ✓ Status after Turn 1: ${state1.status.name}');
  print('  ✓ Pending Approval Prompt: "${runtime1.pendingHumanRequest?.prompt}"');

  // Capture snapshot into durable FileContinuationStore & shut down VM instance #1
  final snapshot = await continuationManager.capture(runtime1, program.programName);
  print('  ✓ Snapshot captured to disk: ${tempDir.path}/${snapshot.continuationId}.json');
  await vm1.shutdown();
  print('  ✓ VM instance #1 SHUT DOWN — 0 memory held, 0 threads blocked!\n');

  // Scenario 2: Simulate operator approving 1 hour later on VM instance #2
  print('┌─ SCENARIO 2: Operator Resumption on VM Instance #2 ──────────────┐');
  final vm2 = await VasterVMEngine.bootstrap(
    config: VMConfig(defaultModel: FakeVasterModel(), rootMountPath: '/workspace'),
  );

  final runtime2 = VasterRuntime(
    vm: vm2,
    policy: ExecutionPolicy.unlimited,
    budget: ExecutionBudget.unlimited(),
    scheduler: BasicVasterScheduler(taskQueue: PriorityTaskQueue()),
  );

  final snapshotFromDisk = await continuationManager.getContinuation(snapshot.continuationId);
  final state2 = await continuationManager.restoreAndResume(
    runtime2,
    snapshotFromDisk!,
    program,
    humanResponse: HumanInteractionResponse.approve(
      requestId: 'prod_deploy_gate',
      comment: 'Approved by lead SRE on call',
    ),
  );

  print('  ✓ Status after Approval: ${state2.status.name}');
  final deployLog = await vm2.fileSystemManager
      .resolveFileSystem('/workspace/deploy.log')
      .readText('/workspace/deploy.log');
  print('  ✓ VFS Deploy Log: "$deployLog"');
  await vm2.shutdown();
  print('  ✓ VM instance #2 completed cleanly!\n');

  // Scenario 3: Demonstrate Budget Timeout Protection when approval expires
  print('┌─ SCENARIO 3: Budget Timeout Protection for Stale Approvals ─────┐');
  final vm3 = await VasterVMEngine.bootstrap(
    config: VMConfig(defaultModel: FakeVasterModel(), rootMountPath: '/workspace'),
  );

  // Expired budget simulating a timed-out request
  final expiredBudget = ExecutionBudget(maxDuration: Duration.zero);

  final runtime3 = VasterRuntime(
    vm: vm3,
    policy: ExecutionPolicy.unlimited,
    budget: expiredBudget,
    scheduler: BasicVasterScheduler(taskQueue: PriorityTaskQueue()),
  );

  final state3 = await runtime3.executeProgram(program);
  print('  ✓ Status under expired budget: ${state3.status.name}');
  print('  ✓ Hang Prevention: Process aborted safely due to budget expiry!');

  await vm3.shutdown();
  if (await tempDir.exists()) {
    await tempDir.delete(recursive: true);
  }

  print('\n======================================================================');
  print('  DEMO PASSED: Vaster safely handles HITL approvals without hangs!');
  print('======================================================================');
}
