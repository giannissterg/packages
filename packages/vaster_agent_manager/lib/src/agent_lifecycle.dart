import 'agent_manager_interface.dart';

/// An agent's lifecycle position, modeled as data.
///
/// The [AgentState] enum answers "which state?"; this sealed hierarchy also
/// answers the questions each state raises — *running what? how much is
/// queued behind it?* — so supervisors and telemetry stop reverse-engineering
/// that context from side channels. Exhaustive switches over it are checked
/// by the compiler; new lifecycle shapes cannot be silently ignored.
sealed class AgentLifecycle {
  const AgentLifecycle();

  /// Projection onto the legacy [AgentState] enum for interface
  /// compatibility.
  AgentState get asState;
}

/// Registered and ready for work; nothing running, nothing queued.
final class AgentIdle extends AgentLifecycle {
  const AgentIdle();

  @override
  AgentState get asState => AgentState.idle;
}

/// One task is executing (agents are actors: exactly one at a time), with
/// [queuedTasks] more serialized behind it.
final class AgentRunning extends AgentLifecycle {
  /// The task currently holding the agent.
  final String activeTaskId;

  /// Tasks accepted but waiting their turn in the agent's mailbox.
  final int queuedTasks;

  const AgentRunning({required this.activeTaskId, this.queuedTasks = 0});

  @override
  AgentState get asState => AgentState.running;
}

/// Dispatch is refused until resumed.
final class AgentPaused extends AgentLifecycle {
  const AgentPaused();

  @override
  AgentState get asState => AgentState.paused;
}

/// Unregistered — terminal.
final class AgentTerminated extends AgentLifecycle {
  const AgentTerminated();

  @override
  AgentState get asState => AgentState.terminated;
}
