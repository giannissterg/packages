import 'package:vaster_model/vaster_model.dart';
import 'package:vaster_session/vaster_session.dart';
import 'package:vaster_agent_descriptor/vaster_agent_descriptor.dart';
import 'agent_output.dart';
import 'agent_task.dart';

/// Abstract interface class defining an autonomous LLM Agent contract.
abstract interface class VasterAgent {
  /// Handle metadata record identifying this agent.
  AgentDescriptor get descriptor;

  /// Unique agent identifier.
  String get agentId => descriptor.agentId;

  /// Session thread bound to this agent.
  ModelSession get session;

  /// Executes an [AgentTask] turn loop (model generation + tool execution).
  Future<AgentOutput> run(
    AgentTask task, {
    CancellationToken? cancelToken,
  });

  /// Spawns a child subagent in an isolated session thread.
  Future<VasterAgent> spawnSubagent({
    required AgentDescriptor descriptor,
    required VasterModel model,
    AgentTask? task,
  });
}
