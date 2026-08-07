import 'package:test/test.dart';
import 'package:vaster_agent_basic/vaster_agent_basic.dart';
import 'package:vaster_context_manager/vaster_context_manager.dart';
import 'package:vaster_model_fake/vaster_model_fake.dart';
import 'package:vaster_resources/vaster_resources.dart';
import 'package:vaster_session/vaster_session.dart';
import 'package:vaster_tool_manager/vaster_tool_manager.dart';

void main() {
  group('BasicVasterAgent', () {
    test('runs task and produces AgentOutput', () async {
      final model = FakeVasterModel(defaultResponseText: 'Agent task complete.');
      final session = BasicModelSession(
        sessionId: 'sess_agent',
        model: model,
        contextManager: BasicContextManager(),
      );

      final agent = BasicVasterAgent(
        descriptor: const AgentDescriptor(
          agentId: 'root_agent',
          name: 'RootAgent',
          role: 'Orchestrator',
          systemInstruction: 'You are root.',
        ),
        session: session,
        resourceTracker: ResourceTracker(quota: ResourceQuota.unlimited),
        toolManager: BasicToolManager(),
      );

      final output = await agent.run(const AgentTask(taskId: 't1', inputPrompt: 'Analyze task requirements'));

      expect(output.isSuccess, isTrue);
      expect(output.outputText, contains('Agent task complete.'));
      expect(output.agentId, equals('root_agent'));
    });

    test('spawns subagent in isolated child session and executes task', () async {
      final model = FakeVasterModel(defaultResponseText: 'Subagent result.');
      final session = BasicModelSession(
        sessionId: 'parent_sess',
        model: model,
        contextManager: BasicContextManager(),
      );

      final rootAgent = BasicVasterAgent(
        descriptor: const AgentDescriptor(
          agentId: 'parent_ag',
          name: 'ParentAgent',
          role: 'Parent',
          systemInstruction: 'Parent agent instruction',
        ),
        session: session,
        resourceTracker: ResourceTracker(quota: ResourceQuota.unlimited),
        toolManager: BasicToolManager(),
      );

      final subagent = await rootAgent.spawnSubagent(
        descriptor: const AgentDescriptor(
          agentId: 'child_ag',
          name: 'ChildAgent',
          role: 'Researcher',
          systemInstruction: 'Research subagent',
        ),
        model: model,
        task: const AgentTask(taskId: 'sub_t1', inputPrompt: 'Research topic details'),
      );

      final subOutput = await subagent.run(
        const AgentTask(taskId: 'sub_t1', inputPrompt: 'Research topic details'),
      );

      expect(subOutput.isSuccess, isTrue);
      expect(subOutput.agentId, equals('child_ag'));
      expect(subOutput.outputText, contains('Subagent result.'));
    });
  });
}
