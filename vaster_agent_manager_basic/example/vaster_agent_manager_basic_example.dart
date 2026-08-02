import 'package:vaster_agent_manager_basic/vaster_agent_manager_basic.dart';
import 'package:vaster_model_fake/vaster_model_fake.dart';
import 'package:vaster_resources/vaster_resources.dart';
import 'package:vaster_session_manager/vaster_session_manager.dart';

void main() async {
  print('=== Vaster Basic Agent Manager Example ===');

  final sessionManager = BasicSessionManager();
  final agentManager = BasicAgentManager(
    sessionManager: sessionManager,
    resourceTracker: ResourceTracker(quota: ResourceQuota.unlimited),
  );

  final model = FakeVasterModel(defaultResponseText: 'Basic agent execution.');

  final agent = await agentManager.createAgent(
    descriptor: const AgentDescriptor(
      agentId: 'basic_ag',
      name: 'BasicAgent',
      role: 'Worker',
      systemInstruction: 'Work.',
    ),
    model: model,
  );

  print('Registered Agent: ${agent.agentId}');

  final output = await agentManager.dispatchTask(
    agentId: 'basic_ag',
    task: const AgentTask(taskId: 't_b', inputPrompt: 'Execute task'),
  );

  print('Output: ${output.outputText}');
}
