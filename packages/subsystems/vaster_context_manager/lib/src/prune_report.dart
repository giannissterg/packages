/// What a lifetime sweep removed — the named contract for
/// `ContextManager.pruneLifetimes` (Rule 11: this shape was an anonymous
/// record re-declared verbatim at three sites).
final class PruneReport {
  /// Ids of the regions removed, in heap order.
  final List<String> prunedIds;

  /// Estimated tokens those regions were holding.
  final int tokensFreed;

  const PruneReport({required this.prunedIds, required this.tokensFreed});

  /// The nothing-swept sweep — also the fold seed for [+].
  static const empty = PruneReport(prunedIds: [], tokensFreed: 0);

  /// Merges two sweeps (the `UsageMetadata` monoid idiom): the composite
  /// manager folds its children's reports instead of hand-merging.
  PruneReport operator +(PruneReport other) => PruneReport(
        prunedIds: [...prunedIds, ...other.prunedIds],
        tokensFreed: tokensFreed + other.tokensFreed,
      );

  @override
  String toString() =>
      'PruneReport(${prunedIds.length} region(s), freed $tokensFreed tok)';
}
