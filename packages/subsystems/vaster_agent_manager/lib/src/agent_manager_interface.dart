import 'package:vaster_agent/vaster_agent.dart';
import 'package:vaster_context_manager/vaster_context_manager.dart';
import 'package:vaster_model/vaster_model.dart';
import 'package:vaster_tool_manager/vaster_tool_manager.dart';

/// Agent lifecycle state flags.
enum AgentState { idle, running, paused, terminated }

/// Node structure representing an agent's hierarchy in a supervisor tree.
class AgentTreeNode {
  final AgentDescriptor descriptor;
  final AgentState state;
  final String? parentAgentId;
  final List<String> childAgentIds;

  const AgentTreeNode({
    required this.descriptor,
    required this.state,
    this.parentAgentId,
    this.childAgentIds = const [],
  });
}

/// Interface defining multi-agent registration, task dispatching, and supervisor tree management.
abstract interface class AgentManager {
  /// Unmodifiable view of active agent descriptors.
  List<AgentDescriptor> get activeDescriptors;

  /// Unmodifiable view of registered agents.
  List<VasterAgent> get activeAgents;

  /// Registers an existing [VasterAgent].
  /// Returns the same-id agent it displaced, null when fresh.
  VasterAgent? registerAgent(VasterAgent agent);

  /// Unregisters an agent by ID.
  bool unregisterAgent(String agentId);

  /// Retrieves a registered [VasterAgent] by ID.
  VasterAgent? getAgent(String agentId);

  /// Gets current [AgentState] of an agent.
  AgentState getAgentState(String agentId);

  /// Spawns a new [VasterAgent] bound to a new session in `SessionManager`.
  ///
  /// [contextManager] and [toolManager] are required owned collaborators
  /// (Rule 5): the caller decides the agent's context topology and tool
  /// surface explicitly — pass `BasicContextManager()` / `BasicToolManager()`
  /// for a bare agent rather than relying on a hidden default.
  Future<VasterAgent> createAgent({
    required AgentDescriptor descriptor,
    required VasterModel model,
    required ContextManager contextManager,
    required ToolManager toolManager,
  });

  /// Dispatches an [AgentTask] to a target agent by ID or [AgentDescriptor].
  Future<AgentOutput> dispatchTask({required String agentId, required AgentTask task});

  /// Dispatches multiple tasks across agents concurrently, preserving input
  /// order in the returned outputs. Part of the interface so the runtime's
  /// DispatchParallelTasksOp works against any manager — a capability this
  /// fundamental must not require downcasting to an implementation.
  Future<List<AgentOutput>> dispatchParallelTasks(List<({String agentId, AgentTask task})> dispatches);

  /// Dispatches an [AgentTask] directly using an [AgentDescriptor] handle.
  Future<AgentOutput> dispatchDescriptorTask({
    required AgentDescriptor agentDescriptor,
    required AgentTask task,
  }) => dispatchTask(agentId: agentDescriptor.agentId, task: task);
}
