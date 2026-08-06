/// Describes a parallel task dispatch entry for the `ParallelTasks` AST node.
class ParallelTaskEntry {
  final String agentId;
  final String prompt;

  /// Binding name for this task's result; auto-allocated when omitted.
  final String? output;

  const ParallelTaskEntry({
    required this.agentId,
    required this.prompt,
    this.output,
  });

  Map<String, dynamic> toJson() => {
        'agentId': agentId,
        'prompt': prompt,
        if (output != null) 'output': output,
      };

  factory ParallelTaskEntry.fromJson(Map<String, dynamic> json) {
    return ParallelTaskEntry(
      agentId: json['agentId'] as String? ?? '',
      prompt: json['prompt'] as String? ?? '',
      output: json['output'] as String?,
    );
  }
}
