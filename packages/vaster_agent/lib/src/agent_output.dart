import 'package:vaster_model/vaster_model.dart';

/// Execution result payload returned by an agent task execution.
class AgentOutput {
  /// Matching task identifier.
  final String taskId;

  /// Agent identifier that performed execution.
  final String agentId;

  /// Final response text produced by agent.
  final String outputText;

  /// Whether task execution was successful.
  final bool isSuccess;

  /// Results returned by spawned subagents during this task.
  final List<AgentOutput> subagentOutputs;

  /// Token/cost usage of THIS agent's own model calls (accumulated across
  /// its tool loop) — excludes subagents; see [aggregateUsage].
  final UsageMetadata usage;

  /// Total execution duration.
  final Duration executionDuration;

  /// Error details if [isSuccess] is false.
  final String? errorDetails;

  const AgentOutput({
    required this.taskId,
    required this.agentId,
    required this.outputText,
    this.isSuccess = true,
    this.subagentOutputs = const [],
    this.usage = const UsageMetadata(),
    this.executionDuration = Duration.zero,
    this.errorDetails,
  });

  /// Usage of the whole task tree: this agent's own calls plus every
  /// subagent's, each counted exactly once.
  UsageMetadata get aggregateUsage =>
      subagentOutputs.fold(usage, (acc, s) => acc + s.aggregateUsage);

  Map<String, dynamic> toJson() => {
        'taskId': taskId,
        'agentId': agentId,
        'outputText': outputText,
        'isSuccess': isSuccess,
        'subagentOutputs': subagentOutputs.map((s) => s.toJson()).toList(),
        if (usage.totalTokenCount != 0 || usage.costUsd != null)
          'usage': usage.toJson(),
        'executionDurationMs': executionDuration.inMilliseconds,
        if (errorDetails != null) 'errorDetails': errorDetails,
      };

  factory AgentOutput.fromJson(Map<String, dynamic> json) {
    final usageRaw = json['usage'] as Map<String, dynamic>?;
    return AgentOutput(
      taskId: json['taskId'] as String? ?? '',
      agentId: json['agentId'] as String? ?? '',
      outputText: json['outputText'] as String? ?? '',
      isSuccess: json['isSuccess'] as bool? ?? true,
      subagentOutputs: (json['subagentOutputs'] as List?)
              ?.map((e) => AgentOutput.fromJson(e as Map<String, dynamic>))
              .toList() ??
          [],
      usage: usageRaw != null
          ? UsageMetadata.fromJson(usageRaw)
          : const UsageMetadata(),
      executionDuration:
          Duration(milliseconds: json['executionDurationMs'] as int? ?? 0),
      errorDetails: json['errorDetails'] as String?,
    );
  }

  @override
  String toString() =>
      'AgentOutput(taskId: "$taskId", agentId: "$agentId", success: $isSuccess, subagents: ${subagentOutputs.length})';
}
