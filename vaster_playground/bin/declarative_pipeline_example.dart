import 'dart:io';

import 'package:vaster_ast/vaster_ast.dart';
import 'package:vaster_budget/vaster_budget.dart';
import 'package:vaster_compiler/vaster_compiler.dart';
import 'package:vaster_continuation_manager/vaster_continuation_manager.dart';
import 'package:vaster_domain/vaster_domain.dart';
import 'package:vaster_model_fake/vaster_model_fake.dart';
import 'package:vaster_policy/vaster_policy.dart';
import 'package:vaster_runtime/vaster_runtime.dart';
import 'package:vaster_scheduler/vaster_scheduler.dart';
import 'package:vaster_vm/vaster_vm.dart';

// ── Typed Context Models ──────────────────────────────────────────────────────
class AppConfig {
  final String appName;
  final String environment;
  const AppConfig({required this.appName, required this.environment});
}

class SecurityRequirement {
  final bool requireEncryption;
  const SecurityRequirement({required this.requireEncryption});
}

// ── Declarative Composable Functional Component ──────────────────────────────
class SecurityAuditComponent extends ComposableNode {
  const SecurityAuditComponent();

  @override
  VasterNode build(BuildContext context) {
    final app = context.get<AppConfig>();
    final sec = context.get<SecurityRequirement>();

    final promptClause = sec.requireEncryption
        ? 'Audit ${app.appName} (${app.environment}) with strict encryption verification.'
        : 'Audit ${app.appName} (${app.environment}) standard checks.';

    return Transaction(children: [
      Prompt(promptClause),
    ]);
  }
}

void main() async {
  print('======================================================================');
  print('  VASTER DECLARATIVE FUNCTIONAL AST & CAPABILITIES PLAYGROUND DEMO     ');
  print('  Pure ComposableNode · Provider<T> · Budget · Scheduler · File Store  ');
  print('======================================================================\n');

  // 1. Setup durable storage directory for continuation snapshots
  final snapshotDir = await Directory.systemTemp.createTemp('vaster_declarative_snapshots_');
  final fileStore = FileContinuationStore(storageDirectory: snapshotDir);
  final continuationManager = BasicContinuationManager(store: fileStore);

  const secAuditorRole = AgentRole(
    roleId: 'sec_auditor',
    name: 'Security Auditor',
    title: 'AppSec Engineer',
    instruction: 'You audit applications for security compliance.',
  );

  // 2. Build Tree-Structured Provider AST (Flutter MaterialApp-style Provider Tree)
  final pipeline = Pipeline(
    spec: const PipelineSpec(name: 'declarative_functional_pipeline'),
    mounts: const [StorageMount(mountPrefix: '/workspace')],
    roles: const [secAuditorRole],
    children: [
      const WriteFile(path: '/workspace/app_spec.txt', content: 'Nexus App Specification'),
      const ReadFile(path: '/workspace/app_spec.txt'),

      // Inject typed configuration into context tree using Provider<T>
      Provider<AppConfig>(
        value: const AppConfig(appName: 'NexusCloud', environment: 'production'),
        children: [
          Provider<SecurityRequirement>(
            value: const SecurityRequirement(requireEncryption: true),
            children: [
              // Agent Scope Provider wrapping its child sub-tree
              Agent(
                role: secAuditorRole,
                children: [
                  // ToolSet Scope Provider
                  ToolSet(
                    tools: const [
                      ToolDefinition(
                        name: 'static_analyzer',
                        description: 'Analyzes code for vulnerabilities',
                      ),
                    ],
                    children: [
                      // Declarative Functional Component (ComposableNode)
                      const SecurityAuditComponent(),

                      // Task automatically inherits secAuditorRole from context!
                      const Task(taskPrompt: 'Produce final compliance report.'),
                    ],
                  ),
                ],
              ),

              // Inline Functional Component Builder
              Component((context) {
                final app = context.get<AppConfig>();
                return WriteFile(
                  path: '/workspace/audit.log',
                  content: 'Audit logged for ${app.appName}',
                );
              }),
            ],
          ),
        ],
      ),

      // Human-in-the-Loop approval gate
      const ApprovalGate(
        requestId: 'deploy_gate',
        prompt: 'Approve deployment of NexusCloud to production?',
        onApprove: [
          WriteFile(path: '/workspace/deploy.log', content: 'Deployed successfully.'),
        ],
      ),

      const Output(),
    ],
  );

  // 3. Compile AST to ISA bytecode
  print('┌─ AST COMPILATION ──────────────────────────────────────────────┐');
  const compiler = BasicWorkflowCompiler();
  final program = compiler.compile(pipeline);
  print('  Pipeline Compiled: ${program.programName}');
  print('  Total Instructions: ${program.instructions.length}\n');

  // 4. Setup Execution Budget & Instruction Scheduler
  final budget = ExecutionBudget(
    maxDuration: const Duration(minutes: 5),
    maxTokens: 50000,
    maxCost: 10.0,
  );
  final scheduler = BasicVasterScheduler(taskQueue: PriorityTaskQueue());

  // 5. Bootstrap VM
  final fakeModel = FakeVasterModel(
    defaultResponseText: 'Audit passed cleanly. Security compliance verified.',
  );
  final vm = await VasterVMEngine.bootstrap(
    config: VMConfig(defaultModel: fakeModel, rootMountPath: '/workspace'),
  );

  // 6. Execute Program Turn #1 (Pauses at HITL)
  print('┌─ RUNTIME EXECUTION (TURN 1) ───────────────────────────────────┐');
  final runtime1 = VasterRuntime(
    vm: vm,
    policy: ExecutionPolicy.unlimited,
    budget: budget,
    scheduler: scheduler,
  );

  var state = await runtime1.executeProgram(program);
  print('  Status: ${state.status.name} (PC: ${state.pc})');
  print('  Pending HITL Request: ${runtime1.pendingHumanRequest?.prompt}\n');

  // 7. Capture snapshot into durable FileContinuationStore
  print('┌─ DURABLE SNAPSHOT PERSISTENCE ─────────────────────────────────┐');
  final snapshot = await continuationManager.capture(runtime1, program.programName);
  print('  Captured Snapshot ID: ${snapshot.continuationId}');
  print('  Persisted to file: ${snapshotDir.path}/${snapshot.continuationId}.json\n');

  // 8. Simulate Process Restart: Load snapshot from disk & resume turn #2
  print('┌─ SNAPSHOT RESTORATION & RESUMPTION (TURN 2) ───────────────────┐');
  final loadedSnapshot = await continuationManager.getContinuation(snapshot.continuationId);

  final runtime2 = VasterRuntime(
    vm: vm,
    policy: ExecutionPolicy.unlimited,
    budget: budget,
    scheduler: scheduler,
  );

  state = await continuationManager.restoreAndResume(
    runtime2,
    loadedSnapshot!,
    program,
    humanResponse: HumanInteractionResponse.approve(
      requestId: 'deploy_gate',
      comment: 'Approved by security team operator',
    ),
  );

  print('✅ Execution HALTED successfully!');
  print('  Final Status: ${state.status.name}');
  print('  Consumed Time: ${budget.consumedDuration.inMilliseconds}ms');
  print('  Output Register: ${state.registers['__output__']}\n');

  // Clean up
  await vm.shutdown();
  if (await snapshotDir.exists()) {
    await snapshotDir.delete(recursive: true);
  }
}
