import 'package:test/test.dart';
import 'package:vaster_agent_manager_advanced/vaster_agent_manager_advanced.dart';
import 'package:vaster_events/vaster_events.dart';
import 'package:vaster_model_fake/vaster_model_fake.dart';
import 'package:vaster_session_manager/vaster_session_manager.dart';

void main() {
  group('AdvancedAgentManager', () {
    late SessionManager sessionManager;
    late RuntimeEventBus eventBus;
    late AdvancedAgentManager agentManager;

    setUp(() {
      sessionManager = BasicSessionManager();
      eventBus = BasicEventBus();
      agentManager = AdvancedAgentManager(
        sessionManager: sessionManager,
        eventBus: eventBus,
        maxTreeDepth: 3,
      );
    });

    tearDown(() async {
      await eventBus.close();
    });

    test('manages supervisor tree hierarchy and pause/resume states', () async {
      final fakeModel = FakeVasterModel();

      final rootAg = await agentManager.createAgent(
        descriptor: const AgentDescriptor(
          agentId: 'root',
          name: 'RootAg',
          role: 'Lead',
          systemInstruction: 'Root',
        ),
        model: fakeModel,
      );

      final childAg = await agentManager.createAgent(
        descriptor: const AgentDescriptor(
          agentId: 'child_1',
          name: 'ChildAg',
          role: 'Worker',
          systemInstruction: 'Worker',
        ),
        model: fakeModel,
        parentAgentId: rootAg.agentId,
      );

      final treeNode = agentManager.getTreeNode(rootAg.agentId);
      expect(treeNode?.childAgentIds, contains('child_1'));

      agentManager.pauseAgent(childAg.agentId);
      expect(agentManager.getAgentState(childAg.agentId), equals(AgentState.paused));

      final output = await agentManager.dispatchTask(
        agentId: childAg.agentId,
        task: const AgentTask(taskId: 't_paused', inputPrompt: 'Do task'),
      );
      expect(output.isSuccess, isFalse);
      expect(output.errorDetails, contains('paused'));

      agentManager.resumeAgent(childAg.agentId);
      expect(agentManager.getAgentState(childAg.agentId), equals(AgentState.idle));
    });

    test('dispatches parallel tasks across subagents', () async {
      final fakeModel = FakeVasterModel(defaultResponseText: 'Parallel output');

      await agentManager.createAgent(
        descriptor: const AgentDescriptor(
          agentId: 'ag1',
          name: 'Ag1',
          role: 'Worker1',
          systemInstruction: 'W1',
        ),
        model: fakeModel,
      );

      await agentManager.createAgent(
        descriptor: const AgentDescriptor(
          agentId: 'ag2',
          name: 'Ag2',
          role: 'Worker2',
          systemInstruction: 'W2',
        ),
        model: fakeModel,
      );

      final outputs = await agentManager.dispatchParallelTasks([
        (agentId: 'ag1', task: const AgentTask(taskId: 'pt1', inputPrompt: 'P1')),
        (agentId: 'ag2', task: const AgentTask(taskId: 'pt2', inputPrompt: 'P2')),
      ]);

      expect(outputs, hasLength(2));
      expect(outputs.every((o) => o.isSuccess), isTrue);
    });

    test('publishes telemetry events to RuntimeEventBus', () async {
      final fakeModel = FakeVasterModel();
      final events = <RuntimeEvent>[];
      eventBus.stream.listen(events.add);

      await agentManager.createAgent(
        descriptor: const AgentDescriptor(
          agentId: 'ag_evt',
          name: 'EvtAg',
          role: 'Worker',
          systemInstruction: 'W',
        ),
        model: fakeModel,
      );

      await agentManager.dispatchTask(
        agentId: 'ag_evt',
        task: const AgentTask(taskId: 'te', inputPrompt: 'Event test'),
      );

      await Future.delayed(const Duration(milliseconds: 20));
      expect(events, hasLength(2));
      expect(events.first, isA<ModelStartedEvent>());
      expect(events.last, isA<ModelFinishedEvent>());
    });

    test('enforces maxTreeDepth limit during subagent creation', () async {
      final fakeModel = FakeVasterModel();

      final a1 = await agentManager.createAgent(
        descriptor: const AgentDescriptor(agentId: 'a1', name: 'A1', role: 'R1', systemInstruction: 'S1'),
        model: fakeModel,
      );

      final a2 = await agentManager.createAgent(
        descriptor: const AgentDescriptor(agentId: 'a2', name: 'A2', role: 'R2', systemInstruction: 'S2'),
        model: fakeModel,
        parentAgentId: a1.agentId,
      );

      final a3 = await agentManager.createAgent(
        descriptor: const AgentDescriptor(agentId: 'a3', name: 'A3', role: 'R3', systemInstruction: 'S3'),
        model: fakeModel,
        parentAgentId: a2.agentId,
      );

      expect(
        () => agentManager.createAgent(
          descriptor: const AgentDescriptor(agentId: 'a4', name: 'A4', role: 'R4', systemInstruction: 'S4'),
          model: fakeModel,
          parentAgentId: a3.agentId,
        ),
        throwsA(isA<StateError>()),
      );
    });
  });
}
