/// Quota limits defining resource constraints for an agent task execution.
class ResourceQuota {
  /// Maximum cumulative tokens (input + output) allowed. Null = unlimited.
  final int? maxTokenBudget;

  /// Maximum tool call loops / executions allowed per task. Null = unlimited.
  final int? maxToolCallsPerTask;

  /// Execution time deadline duration. Null = unlimited.
  final Duration? timeDeadline;

  /// Maximum subagent spawn depth. Null = unlimited.
  final int? maxSubagentDepth;

  /// Maximum cumulative monetary cost allowed. Null = unlimited.
  final double? maxCostBudget;

  const ResourceQuota({
    this.maxTokenBudget,
    this.maxToolCallsPerTask,
    this.timeDeadline,
    this.maxSubagentDepth,
    this.maxCostBudget,
  });

  /// Unlimited resource quota.
  static const ResourceQuota unlimited = ResourceQuota();

  Map<String, dynamic> toJson() => {
        if (maxTokenBudget != null) 'maxTokenBudget': maxTokenBudget,
        if (maxToolCallsPerTask != null) 'maxToolCallsPerTask': maxToolCallsPerTask,
        if (timeDeadline != null) 'timeDeadlineMs': timeDeadline!.inMilliseconds,
        if (maxSubagentDepth != null) 'maxSubagentDepth': maxSubagentDepth,
        if (maxCostBudget != null) 'maxCostBudget': maxCostBudget,
      };

  factory ResourceQuota.fromJson(Map<String, dynamic> json) {
    return ResourceQuota(
      maxTokenBudget: json['maxTokenBudget'] as int?,
      maxToolCallsPerTask: json['maxToolCallsPerTask'] as int?,
      timeDeadline: json['timeDeadlineMs'] != null
          ? Duration(milliseconds: json['timeDeadlineMs'] as int)
          : null,
      maxSubagentDepth: json['maxSubagentDepth'] as int?,
      maxCostBudget: (json['maxCostBudget'] as num?)?.toDouble(),
    );
  }

  @override
  String toString() =>
      'ResourceQuota(tokens: $maxTokenBudget, toolCalls: $maxToolCallsPerTask, deadline: $timeDeadline)';
}
