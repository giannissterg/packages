import 'package:vaster_session/vaster_session.dart';
import 'agent_descriptor.dart';
import 'agent_output.dart';
import 'agent_task.dart';

/// Abstract interface class defining an autonomous agent bound to a [ModelSession].
abstract interface class VasterAgent {
  /// Descriptor metadata handle.
  AgentDescriptor get descriptor;

  /// Agent ID getter.
  String get agentId => descriptor.agentId;

  /// The active [ModelSession] powering this agent.
  ModelSession get session;

  /// Executes an assigned [AgentTask] and returns [AgentOutput].
  Future<AgentOutput> run(AgentTask task);

  /// Spawns a subagent in an isolated child session, executes [task], and returns subagent output.
  Future<AgentOutput> spawnSubagent({
    required AgentDescriptor subagentDescriptor,
    required AgentTask task,
  });
}
