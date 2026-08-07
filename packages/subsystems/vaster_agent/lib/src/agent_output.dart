import 'package:vaster_model/vaster_model.dart';

import 'task_outcome.dart';

/// Execution result payload returned by an agent task execution.
///
/// How the task ended is the sealed [outcome] — `isSuccess` and
/// `errorDetails` are projections kept for callers that only need the
/// bool/string view (the `MachinePhase.asStatus` compatibility move).
class AgentOutput {
  /// Matching task identifier.
  final String taskId;

  /// Agent identifier that performed execution.
  final String agentId;

  /// Final response text produced by agent.
  final String outputText;

  /// How the task ended — sealed, carrying the failure's data.
  final TaskOutcome outcome;

  /// Results returned by spawned subagents during this task.
  final List<AgentOutput> subagentOutputs;

  /// Token/cost usage of THIS agent's own model calls (accumulated across
  /// its tool loop) — excludes subagents; see [aggregateUsage].
  final UsageMetadata usage;

  /// Total execution duration.
  final Duration executionDuration;

  const AgentOutput({
    required this.taskId,
    required this.agentId,
    required this.outputText,
    this.outcome = const TaskCompleted(),
    this.subagentOutputs = const [],
    this.usage = const UsageMetadata(),
    this.executionDuration = Duration.zero,
  });

  /// Projection of [outcome] — prefer switching on the sealed type.
  bool get isSuccess => outcome.isSuccess;

  /// Projection of [outcome] — the failure detail, null on success.
  String? get errorDetails => outcome.isSuccess ? null : outcome.detail;

  /// Usage of the whole task tree: this agent's own calls plus every
  /// subagent's, each counted exactly once.
  UsageMetadata get aggregateUsage => subagentOutputs.fold(usage, (acc, s) => acc + s.aggregateUsage);

  Map<String, dynamic> toJson() => {
    'taskId': taskId,
    'agentId': agentId,
    'outputText': outputText,
    'outcome': outcome.toJson(),
    // Legacy projections stay on the wire for older readers.
    'isSuccess': isSuccess,
    'subagentOutputs': subagentOutputs.map((s) => s.toJson()).toList(),
    if (usage.totalTokenCount != 0 || usage.costUsd != null) 'usage': usage.toJson(),
    'executionDurationMs': executionDuration.inMilliseconds,
    if (errorDetails != null) 'errorDetails': errorDetails,
  };

  factory AgentOutput.fromJson(Map<String, dynamic> json) {
    final usageRaw = json['usage'] as Map<String, dynamic>?;
    final outcomeRaw = json['outcome'] as Map<String, dynamic>?;
    // Legacy payloads (no outcome object): derive from the old bool +
    // string pair — never let a malformed payload masquerade as success
    // when it carried error details.
    final legacySuccess = json['isSuccess'] as bool? ?? true;
    final legacyError = json['errorDetails'] as String?;
    return AgentOutput(
      taskId: json['taskId'] as String? ?? '',
      agentId: json['agentId'] as String? ?? '',
      outputText: json['outputText'] as String? ?? '',
      outcome: outcomeRaw != null
          ? TaskOutcome.fromJson(outcomeRaw)
          : legacySuccess && legacyError == null
          ? const TaskCompleted()
          : TaskFailure(error: legacyError ?? 'unspecified failure'),
      subagentOutputs:
          (json['subagentOutputs'] as List?)
              ?.map((e) => AgentOutput.fromJson(e as Map<String, dynamic>))
              .toList() ??
          [],
      usage: usageRaw != null ? UsageMetadata.fromJson(usageRaw) : const UsageMetadata(),
      executionDuration: Duration(milliseconds: json['executionDurationMs'] as int? ?? 0),
    );
  }

  @override
  String toString() =>
      'AgentOutput(taskId: "$taskId", agentId: "$agentId", '
      'outcome: ${outcome.kind}, subagents: ${subagentOutputs.length})';
}
