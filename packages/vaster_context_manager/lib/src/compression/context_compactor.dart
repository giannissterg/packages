import 'dart:async';

import 'package:vaster_context/vaster_context.dart';

import 'context_compressor.dart';

/// One region's compaction outcome.
final class CompactionEntry {
  final String regionId;
  final String compressorId;
  final int tokensBefore;
  final int tokensAfter;
  final bool lossy;

  const CompactionEntry({
    required this.regionId,
    required this.compressorId,
    required this.tokensBefore,
    required this.tokensAfter,
    required this.lossy,
  });

  @override
  String toString() =>
      'CompactionEntry($regionId: $tokensBefore -> $tokensAfter tok via $compressorId)';
}

/// The result of a compaction pass.
final class CompactionReport {
  final List<CompactionEntry> entries;
  final int tokensFreed;

  /// Total estimated tokens still held after compaction.
  final int tokensRemaining;

  const CompactionReport({
    required this.entries,
    required this.tokensFreed,
    required this.tokensRemaining,
  });

  static const empty =
      CompactionReport(entries: [], tokensFreed: 0, tokensRemaining: 0);

  @override
  String toString() =>
      'CompactionReport(${entries.length} region(s), freed $tokensFreed tok, '
      '$tokensRemaining tok remaining)';
}

/// The shared compaction algorithm used by context managers (budget-pressure
/// pre-pass) and by `CompressContextOp` (explicit compaction).
final class ContextCompactor {
  final List<ContextCompressor> compressors;

  /// Class table used to resolve inherited policy (compressibility, priority)
  /// for regions that don't override it.
  final ContextClassTable classTable;

  /// Regions below this size are never worth compressing.
  final int minRegionTokens;

  const ContextCompactor({
    required this.compressors,
    this.classTable = ContextClassTable.standard,
    this.minRegionTokens = 64,
  });

  ContextCompressibility _compressibilityOf(ContextRegion r) =>
      r.effectiveCompressibility(classTable.resolve(r.classId));

  ContextPriority _priorityOf(ContextRegion r) =>
      r.effectivePriority(classTable.resolve(r.classId));

  /// Classes whose eviction policy is `never` are immutable under pressure:
  /// compressing the system prompt would be as dishonest as evicting it.
  bool _isImmutable(ContextRegion r) =>
      classTable.resolve(r.classId).eviction == EvictionPolicy.never;

  ContextCompressor? _selectFor(ContextCompressibility level) {
    if (level == ContextCompressibility.none) return null;
    if (level == ContextCompressibility.summarize) {
      for (final c in compressors) {
        if (c.level == ContextCompressibility.summarize) return c;
      }
    }
    // truncate regions — or summarize regions with no summarizer available.
    for (final c in compressors) {
      if (c.level == ContextCompressibility.truncate) return c;
    }
    return null;
  }

  /// Compresses [regions] toward [targetTokens] total. Each compressed region
  /// is written back through [apply] (owner-routed so composites land in the
  /// right child heap).
  Future<CompactionReport> compact({
    required List<ContextRegion> regions,
    required int targetTokens,
    required FutureOr<void> Function(ContextRegion compressed) apply,
    bool includePinned = false,
    String? onlyRegionId,
  }) async {
    if (compressors.isEmpty) {
      return CompactionReport(
        entries: const [],
        tokensFreed: 0,
        tokensRemaining: regions.fold(0, (s, r) => s + r.estimatedTokens),
      );
    }

    var total = regions.fold(0, (s, r) => s + r.estimatedTokens);
    var deficit = total - targetTokens;

    // Candidates: compressible, big enough, unpinned unless included, not
    // already compressed, optionally a single target region.
    final candidates = regions
        .where((r) =>
            _compressibilityOf(r) != ContextCompressibility.none &&
            !_isImmutable(r) &&
            r.estimatedTokens >= minRegionTokens &&
            (includePinned || !r.isPinned) &&
            !r.isCompressed &&
            (onlyRegionId == null || r.id == onlyRegionId))
        .toList()
      // Least important, biggest wins first: priority asc, utility asc, size
      // desc; id tie-break keeps the pass deterministic.
      ..sort((a, b) {
        final byPriority =
            _priorityOf(a).index.compareTo(_priorityOf(b).index);
        if (byPriority != 0) return byPriority;
        final byUtility = a.utility.compareTo(b.utility);
        if (byUtility != 0) return byUtility;
        final bySize = b.estimatedTokens.compareTo(a.estimatedTokens);
        if (bySize != 0) return bySize;
        return a.id.compareTo(b.id);
      });

    final entries = <CompactionEntry>[];
    var freed = 0;

    for (final region in candidates) {
      if (deficit <= 0 && onlyRegionId == null) break;

      final compressor = _selectFor(_compressibilityOf(region));
      if (compressor == null) continue;

      // Shrink to 25% (summary-sized) or to exactly-enough-to-cover-the-
      // deficit — whichever keeps MORE content. Explicit single-region
      // compaction uses the caller's target directly.
      final int target;
      if (onlyRegionId != null) {
        target = targetTokens;
      } else {
        final quarter =
            (region.estimatedTokens ~/ 4).clamp(minRegionTokens, region.estimatedTokens);
        final coverDeficit = (region.estimatedTokens - deficit)
            .clamp(minRegionTokens, region.estimatedTokens);
        target = coverDeficit > quarter ? coverDeficit : quarter;
      }

      final result = await compressor.compress(region, targetTokens: target);
      if (result.tokensSaved <= 0) continue;

      await apply(result.region);
      entries.add(CompactionEntry(
        regionId: region.id,
        compressorId: compressor.id,
        tokensBefore: region.estimatedTokens,
        tokensAfter: result.region.estimatedTokens,
        lossy: result.lossy,
      ));
      freed += result.tokensSaved;
      total -= result.tokensSaved;
      deficit = total - targetTokens;
    }

    return CompactionReport(
      entries: entries,
      tokensFreed: freed,
      tokensRemaining: total,
    );
  }
}
