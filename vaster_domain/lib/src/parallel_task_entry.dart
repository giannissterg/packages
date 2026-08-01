/// Describes a parallel task dispatch entry for [PerformParallelTasksNode].
class ParallelTaskEntry {
  final String agentRoleId;
  final String promptText;
  final String? outputVariable;

  const ParallelTaskEntry({
    required this.agentRoleId,
    required this.promptText,
    this.outputVariable,
  });

  Map<String, dynamic> toJson() => {
        'agentRoleId': agentRoleId,
        'promptText': promptText,
        if (outputVariable != null) 'outputVariable': outputVariable,
      };

  factory ParallelTaskEntry.fromJson(Map<String, dynamic> json) {
    return ParallelTaskEntry(
      agentRoleId: json['agentRoleId'] as String? ?? '',
      promptText: json['promptText'] as String? ?? '',
      outputVariable: json['outputVariable'] as String?,
    );
  }
}
