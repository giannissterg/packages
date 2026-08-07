import 'package:vaster_model_fake/vaster_model_fake.dart';
import 'package:vaster_vm/vaster_vm.dart';

void main() async {
  print('================================================================');
  print('          Vaster LLM Virtual Machine Master Engine Demo         ');
  print('================================================================');

  final fakeModel = FakeVasterModel(
    defaultResponseText: 'AI Agent analysis complete. All tasks executed cleanly.',
  );

  final vm = await VasterVMEngine.bootstrap(
    config: VMConfig(
      defaultModel: fakeModel,
      rootMountPath: '/mem',
      defaultQuota: const ResourceQuota(maxTokenBudget: 100000, maxToolCallsPerTask: 10),
    ),
  );

  // Subscribe to VM Telemetry
  vm.eventBus.stream.listen((event) {
    print('  [Telemetry Log] ${event.toJson()}');
  });

  // 1. Mount virtual filesystem and write project spec
  final memoryFs = MemoryVasterFileSystem();
  vm.mountFileSystem('/workspace', memoryFs);
  await memoryFs.writeText('/workspace/spec.md', '# Feature Specification: Auth Service');
  print('1. Mounted Virtual Filesystem & Wrote /workspace/spec.md');

  // 2. Register isolated code sandbox
  final sandbox = IsolateCodeSandbox(
    descriptor: const SandboxDescriptor(
      sandboxId: 'dart_evaluator',
      type: 'isolate',
      description: 'Executes Dart code inside isolated memory sandbox.',
    ),
    evaluator: (code, inputs) => {'status': 'success', 'evalOutput': 'Tests passed!'},
  );
  vm.registerSandbox(sandbox);
  print('2. Registered Code Sandbox (Auto-bridged tool: exec_dart_evaluator)');

  // 3. Register custom function tool
  vm.registerTool(
    FunctionTool.define(
      name: 'fetch_user_db',
      description: 'Fetches mock user record.',
      handler: (args) => {'id': 42, 'name': 'Alice'},
    ),
  );
  print('3. Registered Function Tool: fetch_user_db');

  // 4. Create Lead Developer Agent
  final leadAgent = await vm.createAgent(
    descriptor: const AgentDescriptor(
      agentId: 'lead_arch',
      name: 'LeadArchitect',
      role: 'Software Architect',
      systemInstruction: 'Design and implement features cleanly.',
    ),
  );
  print('4. Created Lead Agent: ${leadAgent.agentId}');

  // 5. Execute Agent Task on VasterVM
  print('\n5. Executing Agent Task on VasterVM...');
  final taskOutput = await vm.runAgentTask(
    const AgentTask(
      taskId: 'task_feature_auth',
      inputPrompt: 'Implement Auth Service feature based on /workspace/spec.md',
    ),
    agentId: leadAgent.agentId,
  );

  print('\n=== Final Execution Output ===');
  print('Agent: ${taskOutput.agentId}');
  print('Status: ${taskOutput.isSuccess ? "SUCCESS" : "FAILED"}');
  print('Result: ${taskOutput.outputText}');
  print('Duration: ${taskOutput.executionDuration.inMilliseconds}ms');

  await Future.delayed(const Duration(milliseconds: 50));
  await vm.shutdown();
  print('\nVM Shutdown Complete!');
}
