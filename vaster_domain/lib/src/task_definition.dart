/// Describes an action task to be dispatched to an agent.
class TaskDefinition {
  /// Unique identifier for this task.
  final String taskId;

  /// The natural-language prompt instructing the agent what to do.
  final String promptText;

  /// Optional register variable name where the agent output is stored.
  final String? outputVariable;

  const TaskDefinition({
    required this.taskId,
    required this.promptText,
    this.outputVariable,
  });

  Map<String, dynamic> toJson() => {
        'taskId': taskId,
        'promptText': promptText,
        if (outputVariable != null) 'outputVariable': outputVariable,
      };

  factory TaskDefinition.fromJson(Map<String, dynamic> json) {
    return TaskDefinition(
      taskId: json['taskId'] as String? ?? '',
      promptText: json['promptText'] as String? ?? '',
      outputVariable: json['outputVariable'] as String?,
    );
  }

  @override
  String toString() => 'TaskDefinition("$taskId")';
}
