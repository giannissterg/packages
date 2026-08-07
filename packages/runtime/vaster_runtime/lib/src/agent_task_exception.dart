import 'package:vaster_agent/vaster_agent.dart';

/// An agent task ended in failure and the dispatching instruction
/// surfaces it as a PROGRAM error — routed to the error-handler stack
/// (`TryCatch`, and therefore `Resilient`) or, unhandled, a trap.
///
/// Before this type existed, a failed agent wrote `''` into its output
/// register and execution continued: `TryCatch` around a `Task` could
/// never fire, so `Resilient` retried nothing. Failure must be
/// observable to be recoverable.
final class AgentTaskException implements Exception {
  final String agentId;
  final String taskId;
  final TaskOutcome outcome;

  const AgentTaskException({required this.agentId, required this.taskId, required this.outcome});

  @override
  String toString() =>
      'Agent task failed [$taskId on $agentId, ${outcome.kind}]: '
      '${outcome.detail}';
}
