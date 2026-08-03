/// Describes a parallel task dispatch entry for the `ParallelTasks` AST node.
class ParallelTaskEntry {
  final String agentRoleId;
  final String promptText;
  final String? output;

  const ParallelTaskEntry({required this.agentRoleId, required this.promptText, this.output});

  Map<String, dynamic> toJson() => {
    'agentRoleId': agentRoleId,
    'promptText': promptText,
    if (output != null) 'outputVariable': output,
  };

  factory ParallelTaskEntry.fromJson(Map<String, dynamic> json) {
    return ParallelTaskEntry(
      agentRoleId: json['agentRoleId'] as String? ?? '',
      promptText: json['promptText'] as String? ?? '',
      output: json['outputVariable'] as String?,
    );
  }
}
