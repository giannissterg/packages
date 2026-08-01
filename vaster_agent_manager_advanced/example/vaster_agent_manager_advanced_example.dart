import 'package:vaster_agent_manager_advanced/vaster_agent_manager_advanced.dart';
import 'package:vaster_events/vaster_events.dart';
import 'package:vaster_model_fake/vaster_model_fake.dart';
import 'package:vaster_session_manager/vaster_session_manager.dart';

void main() async {
  print('=== Vaster Advanced Agent Manager Example ===');

  final sessionManager = BasicSessionManager();
  final eventBus = BasicEventBus();

  eventBus.stream.listen((e) => print('[Event Telemetry] ${e.toJson()}'));

  final manager = AdvancedAgentManager(
    sessionManager: sessionManager,
    eventBus: eventBus,
  );

  final model = FakeVasterModel(defaultResponseText: 'Advanced output');

  final root = await manager.createAgent(
    descriptor: const AgentDescriptor(
      agentId: 'root',
      name: 'RootSupervisor',
      role: 'Lead',
      systemInstruction: 'Lead',
    ),
    model: model,
  );

  await manager.createAgent(
    descriptor: const AgentDescriptor(
      agentId: 'w1',
      name: 'Worker1',
      role: 'Worker',
      systemInstruction: 'W1',
    ),
    model: model,
    parentAgentId: root.agentId,
  );

  print('Supervisor Tree Node for Root: ${manager.getTreeNode(root.agentId)?.childAgentIds}');

  final outputs = await manager.dispatchParallelTasks([
    (agentId: 'w1', task: const AgentTask(taskId: 'pt_1', inputPrompt: 'Task 1')),
  ]);

  print('Parallel Dispatch Result: ${outputs.first.outputText}');

  await Future.delayed(const Duration(milliseconds: 50));
  await eventBus.close();
  print('Done!');
}
