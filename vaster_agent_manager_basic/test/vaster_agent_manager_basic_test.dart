import 'package:test/test.dart';
import 'package:vaster_agent_manager_basic/vaster_agent_manager_basic.dart';
import 'package:vaster_model_fake/vaster_model_fake.dart';
import 'package:vaster_resources/vaster_resources.dart';
import 'package:vaster_session_manager/vaster_session_manager.dart';

void main() {
  group('BasicAgentManager', () {
    late SessionManager sessionManager;
    late BasicAgentManager agentManager;

    setUp(() {
      sessionManager = BasicSessionManager();
      agentManager = BasicAgentManager(
        sessionManager: sessionManager,
        resourceTracker: ResourceTracker(quota: ResourceQuota.unlimited),
      );
    });

    test('creates agent and tracks state', () async {
      final fakeModel = FakeVasterModel();
      await agentManager.createAgent(
        descriptor: const AgentDescriptor(
          agentId: 'b_ag',
          name: 'BasicAg',
          role: 'Role',
          systemInstruction: 'Inst',
        ),
        model: fakeModel,
      );

      expect(agentManager.getAgentState('b_ag'), equals(AgentState.idle));
      final output = await agentManager.dispatchTask(
        agentId: 'b_ag',
        task: const AgentTask(taskId: 't1', inputPrompt: 'Do basic task'),
      );

      expect(output.isSuccess, isTrue);
      expect(agentManager.getAgentState('b_ag'), equals(AgentState.idle));
    });
  });
}
