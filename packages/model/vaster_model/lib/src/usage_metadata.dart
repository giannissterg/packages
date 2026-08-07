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

/// Provenance of a [UsageMetadata]: did the numbers come off the wire, or
/// from a length heuristic?
enum UsageSource {
  /// Reported by the model backend / provider.
  measured,

  /// Derived from a length heuristic (see `vaster_token_estimate`).
  estimated,
}

/// Token usage details for a model invocation.
///
/// Invariant: [promptTokenCount] is the **total billed input**, *including*
/// cache reads and cache writes — [cacheReadTokenCount] and
/// [cacheCreationTokenCount] are a breakdown subset of it, never additional.
/// Backends whose wire format excludes cache tokens from the input count
/// (Anthropic `input_tokens`, llama.cpp `tokens_evaluated`) must add them
/// when constructing this type.
class UsageMetadata {
  /// Total billed input tokens, including cached prefix reads/writes.
  final int promptTokenCount;

  /// Number of tokens generated in candidate output.
  final int candidatesTokenCount;

  /// Internal reasoning/thought tokens (billed as output, not part of
  /// [candidatesTokenCount] on backends that report them separately).
  final int thoughtsTokenCount;

  /// Prompt tokens served from a cached prefix (subset of [promptTokenCount]).
  final int cacheReadTokenCount;

  /// Prompt tokens written to create a cache entry (subset of
  /// [promptTokenCount]).
  final int cacheCreationTokenCount;

  /// Total tokens consumed (prompt + candidate + thoughts unless the wire
  /// reports its own total).
  final int totalTokenCount;

  /// Monetary cost in USD as reported by the backend itself (e.g. the claude
  /// CLI's `total_cost_usd`). Null when the wire reports no cost — computed
  /// pricing is a separate concern (`vaster_pricing`), never stored here.
  final double? costUsd;

  /// Whether these numbers were measured off the wire or estimated. Defaults
  /// to [UsageSource.estimated] so the blank `const UsageMetadata()` a
  /// backend falls back to reads as untrusted; parsers of real wire data set
  /// [UsageSource.measured] explicitly.
  final UsageSource source;

  const UsageMetadata({
    this.promptTokenCount = 0,
    this.candidatesTokenCount = 0,
    this.thoughtsTokenCount = 0,
    this.cacheReadTokenCount = 0,
    this.cacheCreationTokenCount = 0,
    int? totalTokenCount,
    this.costUsd,
    this.source = UsageSource.estimated,
  }) : totalTokenCount = totalTokenCount ?? (promptTokenCount + candidatesTokenCount + thoughtsTokenCount);

  /// Whether this is the additive identity: no tokens, no cost. A neutral
  /// operand (e.g. a zero accumulator seed) never affects the sum's [source].
  bool get isZero => totalTokenCount == 0 && costUsd == null;

  /// Field-wise sum, for aggregating usage across multiple calls.
  ///
  /// [costUsd] is null-aware (null + x = x); the result is [UsageSource
  /// .measured] only when every non-[isZero] operand is measured — one
  /// estimated input taints the aggregate, but a zero seed does not.
  UsageMetadata operator +(UsageMetadata other) => UsageMetadata(
    promptTokenCount: promptTokenCount + other.promptTokenCount,
    candidatesTokenCount: candidatesTokenCount + other.candidatesTokenCount,
    thoughtsTokenCount: thoughtsTokenCount + other.thoughtsTokenCount,
    cacheReadTokenCount: cacheReadTokenCount + other.cacheReadTokenCount,
    cacheCreationTokenCount: cacheCreationTokenCount + other.cacheCreationTokenCount,
    totalTokenCount: totalTokenCount + other.totalTokenCount,
    costUsd: costUsd == null && other.costUsd == null ? null : (costUsd ?? 0) + (other.costUsd ?? 0),
    source:
        (isZero || source == UsageSource.measured) &&
            (other.isZero || other.source == UsageSource.measured) &&
            !(isZero && other.isZero)
        ? UsageSource.measured
        : UsageSource.estimated,
  );

  /// New keys are emitted only when non-default so payloads produced before
  /// they existed stay byte-identical (tape/golden compatibility).
  Map<String, dynamic> toJson() => {
    'promptTokenCount': promptTokenCount,
    'candidatesTokenCount': candidatesTokenCount,
    'totalTokenCount': totalTokenCount,
    if (thoughtsTokenCount != 0) 'thoughtsTokenCount': thoughtsTokenCount,
    if (cacheReadTokenCount != 0) 'cacheReadTokenCount': cacheReadTokenCount,
    if (cacheCreationTokenCount != 0) 'cacheCreationTokenCount': cacheCreationTokenCount,
    if (costUsd != null) 'costUsd': costUsd,
    if (source != UsageSource.estimated) 'source': source.name,
  };

  factory UsageMetadata.fromJson(Map<String, dynamic> json) {
    final prompt = json['promptTokenCount'] as int? ?? 0;
    final candidate = json['candidatesTokenCount'] as int? ?? 0;
    final thoughts = json['thoughtsTokenCount'] as int? ?? 0;
    return UsageMetadata(
      promptTokenCount: prompt,
      candidatesTokenCount: candidate,
      thoughtsTokenCount: thoughts,
      cacheReadTokenCount: json['cacheReadTokenCount'] as int? ?? 0,
      cacheCreationTokenCount: json['cacheCreationTokenCount'] as int? ?? 0,
      totalTokenCount: json['totalTokenCount'] as int? ?? (prompt + candidate + thoughts),
      costUsd: (json['costUsd'] as num?)?.toDouble(),
      source: json['source'] == UsageSource.measured.name ? UsageSource.measured : UsageSource.estimated,
    );
  }

  @override
  String toString() =>
      'UsageMetadata(prompt: $promptTokenCount, output: $candidatesTokenCount, '
      'total: $totalTokenCount, ${source.name}'
      '${costUsd != null ? ', \$$costUsd' : ''})';
}
