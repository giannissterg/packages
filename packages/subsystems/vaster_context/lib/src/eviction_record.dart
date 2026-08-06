/// Why a region was evicted from the compiled context.
enum EvictionReason {
  /// The region did not fit the token budget during allocation.
  budgetExceeded,

  /// The region's lifetime expired at a step/turn boundary.
  lifetimeExpired,

  /// The region was explicitly evicted (API call or EvictContextOp).
  explicit,
}

/// Attribution record explaining a single eviction decision.
final class EvictionRecord {
  final String regionId;
  final EvictionReason reason;

  /// Estimated tokens of the evicted region.
  final int regionTokens;

  /// Input-budget tokens still available when the decision was made.
  final int tokensAvailableAtDecision;

  const EvictionRecord({
    required this.regionId,
    required this.reason,
    required this.regionTokens,
    this.tokensAvailableAtDecision = 0,
  });

  @override
  String toString() =>
      'EvictionRecord($regionId, ${reason.name}, ${regionTokens}tok, '
      '${tokensAvailableAtDecision}tok available)';
}
