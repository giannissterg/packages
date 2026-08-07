import 'package:vaster_agent_basic/vaster_agent_basic.dart';
import 'package:vaster_context_manager/vaster_context_manager.dart';
import 'package:vaster_model_fake/vaster_model_fake.dart';
import 'package:vaster_resources/vaster_resources.dart';
import 'package:vaster_session/vaster_session.dart';
import 'package:vaster_tool_manager/vaster_tool_manager.dart';

void main() async {
  print('=== Vaster Basic Agent Example ===');

  final fakeModel = FakeVasterModel(defaultResponseText: 'Execution finished.');
  final session = BasicModelSession(
    sessionId: 'sess_demo',
    model: fakeModel,
    contextManager: BasicContextManager(),
  );

  final agent = BasicVasterAgent(
    descriptor: const AgentDescriptor(
      agentId: 'coder',
      name: 'CoderAgent',
      role: 'Software Developer',
      systemInstruction: 'Write high quality code.',
    ),
    session: session,
    resourceTracker: ResourceTracker(quota: ResourceQuota.unlimited),
    toolManager: BasicToolManager(),
  );

  final output = await agent.run(const AgentTask(taskId: 'task_001', inputPrompt: 'Implement binary search'));

  print('Agent Output: ${output.outputText}');
}
