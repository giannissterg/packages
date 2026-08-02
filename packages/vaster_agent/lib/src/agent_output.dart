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
    this.executionDuration = Duration.zero,
    this.errorDetails,
  });

  Map<String, dynamic> toJson() => {
        'taskId': taskId,
        'agentId': agentId,
        'outputText': outputText,
        'isSuccess': isSuccess,
        'subagentOutputs': subagentOutputs.map((s) => s.toJson()).toList(),
        'executionDurationMs': executionDuration.inMilliseconds,
        if (errorDetails != null) 'errorDetails': errorDetails,
      };

  factory AgentOutput.fromJson(Map<String, dynamic> json) {
    return AgentOutput(
      taskId: json['taskId'] as String? ?? '',
      agentId: json['agentId'] as String? ?? '',
      outputText: json['outputText'] as String? ?? '',
      isSuccess: json['isSuccess'] as bool? ?? true,
      subagentOutputs: (json['subagentOutputs'] as List?)
              ?.map((e) => AgentOutput.fromJson(e as Map<String, dynamic>))
              .toList() ??
          [],
      executionDuration:
          Duration(milliseconds: json['executionDurationMs'] as int? ?? 0),
      errorDetails: json['errorDetails'] as String?,
    );
  }

  @override
  String toString() =>
      'AgentOutput(taskId: "$taskId", agentId: "$agentId", success: $isSuccess, subagents: ${subagentOutputs.length})';
}
