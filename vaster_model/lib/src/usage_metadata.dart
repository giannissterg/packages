/// Reason why the model finished generating output.
enum FinishReason {
  /// Generation reached a natural stop token or end of message.
  stop,

  /// Generation hit max output token limit.
  maxTokens,

  /// Generation stopped because the model emitted tool/function calls.
  toolCalls,

  /// Generation blocked due to safety or policy filters.
  safety,

  /// Generation failed due to an execution error.
  error,

  /// Unspecified or unknown finish reason.
  unknown,
}

/// Token usage details for a model invocation.
class UsageMetadata {
  /// Number of tokens in the prompt / input context.
  final int promptTokenCount;

  /// Number of tokens generated in candidate output.
  final int candidatesTokenCount;

  /// Total tokens consumed (prompt + candidate).
  final int totalTokenCount;

  const UsageMetadata({
    this.promptTokenCount = 0,
    this.candidatesTokenCount = 0,
    int? totalTokenCount,
  }) : totalTokenCount = totalTokenCount ?? (promptTokenCount + candidatesTokenCount);

  Map<String, dynamic> toJson() => {
        'promptTokenCount': promptTokenCount,
        'candidatesTokenCount': candidatesTokenCount,
        'totalTokenCount': totalTokenCount,
      };

  factory UsageMetadata.fromJson(Map<String, dynamic> json) {
    final prompt = json['promptTokenCount'] as int? ?? 0;
    final candidate = json['candidatesTokenCount'] as int? ?? 0;
    final total = json['totalTokenCount'] as int? ?? (prompt + candidate);
    return UsageMetadata(
      promptTokenCount: prompt,
      candidatesTokenCount: candidate,
      totalTokenCount: total,
    );
  }

  @override
  String toString() =>
      'UsageMetadata(prompt: $promptTokenCount, output: $candidatesTokenCount, total: $totalTokenCount)';
}
