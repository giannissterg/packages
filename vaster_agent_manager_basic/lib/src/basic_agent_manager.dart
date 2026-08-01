import 'package:vaster_agent_basic/vaster_agent_basic.dart';
import 'package:vaster_agent_manager/vaster_agent_manager.dart';
import 'package:vaster_context_manager/vaster_context_manager.dart';
import 'package:vaster_model/vaster_model.dart';
import 'package:vaster_session_manager/vaster_session_manager.dart';
import 'package:vaster_tool_manager/vaster_tool_manager.dart';

/// Standard basic implementation of [AgentManager] integrated with [SessionManager].
class BasicAgentManager implements AgentManager {
  final SessionManager sessionManager;
  final Map<String, VasterAgent> _agents = {};
  final Map<String, AgentState> _states = {};

  BasicAgentManager({
    required this.sessionManager,
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
  void registerAgent(VasterAgent agent) {
    _agents[agent.agentId] = agent;
    _states[agent.agentId] = AgentState.idle;
  }

  @override
  bool unregisterAgent(String agentId) {
    _states.remove(agentId);
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

  @override
  Future<VasterAgent> createAgent({
    required AgentDescriptor descriptor,
    required VasterModel model,
    ContextManager? contextManager,
    ToolManager? toolManager,
  }) async {
    final sessionId = 'sess_${descriptor.agentId}';
    final session = await sessionManager.createSession(
      sessionId: sessionId,
      model: model,
      contextManager: contextManager,
    );

    final agent = BasicVasterAgent(
      descriptor: descriptor,
      session: session,
      toolManager: toolManager,
    );

    registerAgent(agent);
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
        errorDetails: 'Agent "$agentId" is not registered in AgentManager.',
      );
    }

    _states[agentId] = AgentState.running;
    try {
      final output = await agent.run(task);
      _states[agentId] = AgentState.idle;
      return output;
    } catch (e) {
      _states[agentId] = AgentState.idle;
      rethrow;
    }
  }
}
