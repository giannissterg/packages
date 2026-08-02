import 'dart:async';
import 'package:vaster_agent_basic/vaster_agent_basic.dart';
import 'package:vaster_agent_manager/vaster_agent_manager.dart';
import 'package:vaster_context_manager/vaster_context_manager.dart';
import 'package:vaster_events/vaster_events.dart';
import 'package:vaster_model/vaster_model.dart';
import 'package:vaster_resources/vaster_resources.dart';
import 'package:vaster_session_manager/vaster_session_manager.dart';
import 'package:vaster_tool_manager/vaster_tool_manager.dart';

/// Advanced supervisor implementation of [AgentManager] featuring supervisor trees,
/// parallel task dispatching, lifecycle states, and optional [RuntimeEventBus] telemetry.
class AdvancedAgentManager implements AgentManager {
  final SessionManager sessionManager;
  final RuntimeEventBus? eventBus;

  /// Optional VM-level resource tracker forwarded to every agent at construction.
  /// If null, agents are constructed with [ResourceQuota.unlimited].
  final ResourceTracker? resourceTracker;

  final int maxTreeDepth;

  final Map<String, VasterAgent> _agents = {};
  final Map<String, AgentState> _states = {};
  final Map<String, String> _parents = {}; // childId -> parentId
  final Map<String, List<String>> _children = {}; // parentId -> [childIds]

  AdvancedAgentManager({
    required this.sessionManager,
    this.eventBus,
    this.resourceTracker,
    this.maxTreeDepth = 5,
    List<VasterAgent>? initialAgents,
  }) {
    if (initialAgents != null) {
      for (final agent in initialAgents) {
        registerAgent(agent);
      }
    }
  }

  @override
  List<AgentDescriptor> get activeDescriptors =>
      List.unmodifiable(_agents.values.map((a) => a.descriptor));

  @override
  List<VasterAgent> get activeAgents => List.unmodifiable(_agents.values);

  @override
  void registerAgent(VasterAgent agent, {String? parentAgentId}) {
    _agents[agent.agentId] = agent;
    _states[agent.agentId] = AgentState.idle;
    _children.putIfAbsent(agent.agentId, () => []);

    if (parentAgentId != null) {
      _parents[agent.agentId] = parentAgentId;
      _children.putIfAbsent(parentAgentId, () => []).add(agent.agentId);
    }
  }

  @override
  bool unregisterAgent(String agentId) {
    _states[agentId] = AgentState.terminated;
    final parentId = _parents.remove(agentId);
    if (parentId != null) {
      _children[parentId]?.remove(agentId);
    }
    _children.remove(agentId);
    return _agents.remove(agentId) != null;
  }

  @override
  VasterAgent? getAgent(String agentId) {
    return _agents[agentId];
  }

  @override
  AgentState getAgentState(String agentId) {
    return _states[agentId] ?? AgentState.terminated;
  }

  /// Pauses an agent execution state.
  void pauseAgent(String agentId) {
    if (_agents.containsKey(agentId)) {
      _states[agentId] = AgentState.paused;
    }
  }

  /// Resumes a paused agent.
  void resumeAgent(String agentId) {
    if (_agents.containsKey(agentId)) {
      _states[agentId] = AgentState.idle;
    }
  }

  /// Returns supervisor tree node info for an agent.
  AgentTreeNode? getTreeNode(String agentId) {
    final agent = getAgent(agentId);
    if (agent == null) return null;

    return AgentTreeNode(
      descriptor: agent.descriptor,
      state: getAgentState(agentId),
      parentAgentId: _parents[agentId],
      childAgentIds: List.unmodifiable(_children[agentId] ?? []),
    );
  }

  @override
  Future<VasterAgent> createAgent({
    required AgentDescriptor descriptor,
    required VasterModel model,
    ContextManager? contextManager,
    ToolManager? toolManager,
    String? parentAgentId,
  }) async {
    if (parentAgentId != null) {
      int depth = _calculateDepth(parentAgentId);
      if (depth >= maxTreeDepth) {
        throw StateError(
            'Cannot spawn subagent: Supervisor tree depth limit ($maxTreeDepth) reached.');
      }
    }

    final sessionId = 'sess_${descriptor.agentId}';
    final session = await sessionManager.createSession(
      sessionId: sessionId,
      model: model,
      contextManager: contextManager,
    );

    final agent = BasicVasterAgent(
      descriptor: descriptor,
      session: session,
      resourceTracker: resourceTracker ?? ResourceTracker(quota: ResourceQuota.unlimited),
      toolManager: toolManager,
    );

    registerAgent(agent, parentAgentId: parentAgentId);
    return agent;
  }

  @override
  Future<AgentOutput> dispatchTask({
    required String agentId,
    required AgentTask task,
  }) async {
    final agent = getAgent(agentId);
    if (agent == null) {
      return AgentOutput(
        taskId: task.taskId,
        agentId: agentId,
        outputText: '',
        isSuccess: false,
        errorDetails: 'Agent "$agentId" is not registered in AdvancedAgentManager.',
      );
    }

    if (getAgentState(agentId) == AgentState.paused) {
      return AgentOutput(
        taskId: task.taskId,
        agentId: agentId,
        outputText: '',
        isSuccess: false,
        errorDetails: 'Agent "$agentId" is currently paused.',
      );
    }

    _states[agentId] = AgentState.running;

    eventBus?.publish(ModelStartedEvent(
      eventId: 'evt_start_${task.taskId}',
      sessionId: agent.session.sessionId,
      modelName: agent.session.model.modelName,
      promptTokenCount: task.inputPrompt.length ~/ 4,
    ));

    try {
      final output = await agent.run(task);
      _states[agentId] = AgentState.idle;

      eventBus?.publish(ModelFinishedEvent(
        eventId: 'evt_finish_${task.taskId}',
        sessionId: agent.session.sessionId,
        finishReason: 'stop',
        totalTokens: output.outputText.length ~/ 4,
        executionDuration: output.executionDuration,
      ));

      return output;
    } catch (e) {
      _states[agentId] = AgentState.idle;
      rethrow;
    }
  }

  @override
  Future<AgentOutput> dispatchDescriptorTask({
    required AgentDescriptor agentDescriptor,
    required AgentTask task,
  }) =>
      dispatchTask(agentId: agentDescriptor.agentId, task: task);

  /// Dispatches multiple tasks across agents in parallel.
  Future<List<AgentOutput>> dispatchParallelTasks(
    List<({String agentId, AgentTask task})> dispatches,
  ) async {
    final futures = dispatches.map((d) => dispatchTask(
          agentId: d.agentId,
          task: d.task,
        ));
    return await Future.wait(futures);
  }

  int _calculateDepth(String agentId) {
    int depth = 1;
    String? current = _parents[agentId];
    while (current != null) {
      depth++;
      current = _parents[current];
    }
    return depth;
  }
}
