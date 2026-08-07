import 'package:test/test.dart';
import 'package:vaster_agent_manager_advanced/vaster_agent_manager_advanced.dart';
import 'package:vaster_context/vaster_context.dart';
import 'package:vaster_context_manager/vaster_context_manager.dart';
import 'package:vaster_events/vaster_events.dart';
import 'package:vaster_model/vaster_model.dart';
import 'package:vaster_model_fake/vaster_model_fake.dart';
import 'package:vaster_resources/vaster_resources.dart';
import 'package:vaster_session_manager/vaster_session_manager.dart';
import 'package:vaster_tool_manager/vaster_tool_manager.dart';

void main() {
  group('Multi-Subagent Context Propagation & Supervision', () {
    late SessionManager sessionManager;
    late ContextManager contextManager;
    late RuntimeEventBus eventBus;
    late AdvancedAgentManager agentManager;
    late FakeVasterModel fakeModel;

    setUp(() async {
      sessionManager = BasicSessionManager();
      contextManager = BasicContextManager();
      eventBus = BasicEventBus();
      fakeModel = FakeVasterModel(defaultResponseText: 'Subagent context verified.');

      agentManager = AdvancedAgentManager(
        sessionManager: sessionManager,
        eventBus: eventBus,
        resourceTracker: ResourceTracker(quota: ResourceQuota.unlimited),
        maxTreeDepth: 5,
      );

      // Register shared parent system context source
      final sharedSource = MemoryContextSource.fromMap(
        id: 'shared_architecture_spec',
        name: 'Shared Architecture Guidelines',
        data: {'system': 'System Rule: All microservices must use JSON over HTTP.'},
        isPinned: true,
      );
      contextManager.registerSource(sharedSource);
    });

    tearDown(() async {
      await eventBus.close();
    });

    test('propagates context and system instructions across multi-subagent supervisor tree', () async {
      // 1. Create Root Lead Agent
      final leadAgent = await agentManager.createAgent(
        descriptor: const AgentDescriptor(
          agentId: 'lead_architect',
          name: 'LeadArchitect',
          role: 'Lead Architect',
          systemInstruction: 'You lead the team.',
        ),
        model: fakeModel,
        toolManager: BasicToolManager(),
        contextManager: contextManager,
      );

      // 2. Create Subagent 1 (Coder) under Lead Architect
      final coderAgent = await agentManager.createAgent(
        descriptor: const AgentDescriptor(
          agentId: 'sub_coder',
          name: 'CoderSubagent',
          role: 'Backend Coder',
          systemInstruction: 'You write Dart backend code.',
        ),
        model: fakeModel,
        toolManager: BasicToolManager(),
        contextManager: contextManager,
        parentAgentId: leadAgent.agentId,
      );

      // 3. Create Subagent 2 (Tester) under Lead Architect
      final testerAgent = await agentManager.createAgent(
        descriptor: const AgentDescriptor(
          agentId: 'sub_tester',
          name: 'TesterSubagent',
          role: 'QA Engineer',
          systemInstruction: 'You write unit tests.',
        ),
        model: fakeModel,
        toolManager: BasicToolManager(),
        contextManager: contextManager,
        parentAgentId: leadAgent.agentId,
      );

      // 4. Verify supervisor tree structure
      final treeNode = agentManager.getTreeNode(leadAgent.agentId);
      expect(treeNode?.childAgentIds, containsAll(['sub_coder', 'sub_tester']));

      // 5. Verify isolated sessions created in SessionManager
      expect(sessionManager.getSession('sess_sub_coder'), isNotNull);
      expect(sessionManager.getSession('sess_sub_tester'), isNotNull);

      // 6. Verify context propagation in child subagent session
      final coderSession = sessionManager.getSession('sess_sub_coder')!;
      final compiled = await coderSession.contextManager.compileContext(
        budget: const TokenBudget(maxContextTokens: 1000, reservedOutputTokens: 200, reservedToolTokens: 0),
      );

      expect(compiled.systemInstruction?.parts.first, isA<TextPart>());
      expect((compiled.systemInstruction!.parts.first as TextPart).text, contains('JSON over HTTP'));

      // 7. Dispatch parallel tasks across subagents and verify outputs
      final outputs = await agentManager.dispatchParallelTasks([
        (
          agentId: coderAgent.agentId,
          task: const AgentTask(taskId: 'task_coder', inputPrompt: 'Implement Auth Endpoint'),
        ),
        (
          agentId: testerAgent.agentId,
          task: const AgentTask(taskId: 'task_tester', inputPrompt: 'Write Auth Endpoint Test'),
        ),
      ]);

      expect(outputs, hasLength(2));
      expect(outputs[0].agentId, equals('sub_coder'));
      expect(outputs[1].agentId, equals('sub_tester'));
      expect(outputs[0].isSuccess, isTrue);
      expect(outputs[1].isSuccess, isTrue);
    });
  });
}
