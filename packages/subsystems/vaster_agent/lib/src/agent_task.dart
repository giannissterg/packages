/// Input task payload assigned to an agent.
class AgentTask {
  /// Unique task identifier.
  final String taskId;

  /// User prompt or goal description.
  final String inputPrompt;

  /// Task priority (higher number = higher priority).
  final int priority;

  /// Input payload arguments / context metadata.
  final Map<String, dynamic> metadata;

  const AgentTask({
    required this.taskId,
    required this.inputPrompt,
    this.priority = 10,
    this.metadata = const {},
  });

  Map<String, dynamic> toJson() => {
    'taskId': taskId,
    'inputPrompt': inputPrompt,
    'priority': priority,
    if (metadata.isNotEmpty) 'metadata': metadata,
  };

  factory AgentTask.fromJson(Map<String, dynamic> json) {
    return AgentTask(
      taskId: json['taskId'] as String? ?? '',
      inputPrompt: json['inputPrompt'] as String? ?? '',
      priority: json['priority'] as int? ?? 10,
      metadata: Map<String, dynamic>.from(json['metadata'] as Map? ?? {}),
    );
  }

  @override
  String toString() => 'AgentTask(id: "$taskId", priority: $priority, promptLength: ${inputPrompt.length})';
}
