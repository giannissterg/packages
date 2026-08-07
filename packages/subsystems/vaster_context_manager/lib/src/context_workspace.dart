import 'package:vaster_context/vaster_context.dart';
import 'package:vaster_model/vaster_model.dart';

import 'compression/context_compactor.dart';
import 'context_manager_interface.dart';

/// One row of a context inspection report.
final class ContextRegionInfo {
  final String id;
  final String label;
  final int tokens;
  final double sharePercent;
  final ContextPriority priority;
  final ContextLifetime lifetime;
  final ContextCompressibility compressibility;
  final bool isPinned;
  final bool isCompressed;
  final double utility;

  const ContextRegionInfo({
    required this.id,
    required this.label,
    required this.tokens,
    required this.sharePercent,
    required this.priority,
    required this.lifetime,
    required this.compressibility,
    required this.isPinned,
    required this.isCompressed,
    required this.utility,
  });
}

/// A point-in-time view of everything the context manager holds, plus the
/// outcome of the most recent compilation.
final class ContextInspectionReport {
  final int totalTokens;
  final int regionCount;
  final int pinnedTokens;
  final List<ContextRegionInfo> rows; // sorted by tokens desc
  final List<String> lastIncludedIds;
  final List<EvictionRecord> lastEvictionRecords;

  const ContextInspectionReport({
    required this.totalTokens,
    required this.regionCount,
    required this.pinnedTokens,
    required this.rows,
    required this.lastIncludedIds,
    required this.lastEvictionRecords,
  });

  /// Renders a human-readable table for CLI/debug output.
  String toPrettyString() {
    final buffer = StringBuffer()
      ..writeln('── CONTEXT HEAP ────────────────────────────────────────────')
      ..writeln(
        'regions: $regionCount   total: ~$totalTokens tok   '
        'pinned: ~$pinnedTokens tok',
      );
    for (final row in rows) {
      final flags = [if (row.isPinned) 'PIN', if (row.isCompressed) 'ZIP'].join(',');
      buffer.writeln(
        '  ${row.id.padRight(28)} ${row.tokens.toString().padLeft(7)} tok '
        '${row.sharePercent.toStringAsFixed(1).padLeft(5)}%  '
        '${row.priority.name.padRight(9)} ${row.lifetime.name.padRight(10)} '
        '${row.compressibility.name.padRight(9)} '
        '${flags.isEmpty ? '-' : flags}',
      );
    }
    if (lastEvictionRecords.isNotEmpty) {
      buffer.writeln('── last compile evictions ─────────────────────────────');
      for (final record in lastEvictionRecords) {
        buffer.writeln(
          '  ${record.regionId}: ${record.reason.name} '
          '(${record.regionTokens} tok, ${record.tokensAvailableAtDecision} available)',
        );
      }
    }
    return buffer.toString();
  }
}

/// High-level, ergonomic context management facade over any [ContextManager].
///
/// Every mutator returns whether it took effect (no silent no-ops), all
/// updates are in-place (no heap reordering), and the facade behaves
/// identically over [BasicContextManager] and [CompositeContextManager]
/// because it uses only the routed region-level interface.
final class ContextWorkspace {
  final ContextManager manager;

  const ContextWorkspace(this.manager);

  // ── Inspection ─────────────────────────────────────────────────────────

  List<ContextRegion> get regions => manager.regions;

  ContextRegion? region(String id) => manager.getRegion(id);

  ContextInspectionReport inspect() {
    final all = manager.regions;
    final total = all.fold(0, (s, r) => s + r.estimatedTokens);
    final rows =
        all
            .map(
              (r) => ContextRegionInfo(
                id: r.id,
                label: r.label,
                tokens: r.estimatedTokens,
                sharePercent: total == 0 ? 0 : r.estimatedTokens * 100 / total,
                priority: r.priorityOrDefault,
                lifetime: r.lifetimeOrDefault,
                compressibility: r.compressibilityOrDefault,
                isPinned: r.isPinned,
                isCompressed: r.isCompressed,
                utility: r.utility,
              ),
            )
            .toList()
          ..sort((a, b) => b.tokens.compareTo(a.tokens));

    final last = manager.lastCompiled;
    return ContextInspectionReport(
      totalTokens: total,
      regionCount: all.length,
      pinnedTokens: all.where((r) => r.isPinned).fold(0, (s, r) => s + r.estimatedTokens),
      rows: rows,
      lastIncludedIds: last?.includedRegions.map((r) => r.id).toList() ?? const [],
      lastEvictionRecords: last?.evictionRecords ?? const [],
    );
  }

  // ── Mutation ───────────────────────────────────────────────────────────

  void add(ContextRegion region) => manager.addRegion(region);

  /// Convenience: add a text region in one call.
  void addText({
    required String id,
    required String label,
    required String text,
    Role role = Role.user,
    ContextPriority priority = ContextPriority.medium,
    ContextLifetime lifetime = ContextLifetime.session,
    ContextCompressibility compressibility = ContextCompressibility.none,
    bool pinned = false,
  }) {
    manager.addRegion(
      ContextRegion.text(
        id: id,
        label: label,
        role: role,
        text: text,
        priority: priority,
        lifetime: lifetime,
        compressibility: compressibility,
        isPinned: pinned,
      ),
    );
  }

  bool remove(String id, {bool force = false}) => manager.removeRegion(id, force: force);

  bool update(String id, ContextRegion Function(ContextRegion) transform) =>
      manager.updateRegion(id, transform);

  bool setPriority(String id, ContextPriority priority) =>
      manager.updateRegion(id, (r) => r.copyWith(priority: priority));

  bool setCompressibility(String id, ContextCompressibility compressibility) =>
      manager.updateRegion(id, (r) => r.copyWith(compressibility: compressibility));

  bool setUtility(String id, double utility) => manager.updateRegion(id, (r) => r.copyWith(utility: utility));

  bool pin(String id) {
    if (manager.getRegion(id) == null) return false;
    manager.pinRegion(id);
    return true;
  }

  bool unpin(String id) {
    if (manager.getRegion(id) == null) return false;
    manager.unpinRegion(id);
    return true;
  }

  /// Restores a compressed region's original messages (when the compressor
  /// preserved them). Returns false when not compressed or originals were
  /// discarded (lossy).
  bool expand(String id) {
    final region = manager.getRegion(id);
    final originals = region?.compression?.originalMessages;
    if (region == null || originals == null) return false;
    return manager.updateRegion(
      id,
      (r) => r.copyWith(
        messages: List<ChatMessage>.of(originals),
        estimatedTokens: r.compression!.tokensBefore,
        clearCompression: true,
      ),
    );
  }

  /// Compresses the heap toward the budget's input allowance.
  Future<CompactionReport> compact({required TokenBudget budget, bool includePinned = false}) => manager
      .compact(targetTokens: (budget.availableInputBudget * 0.9).floor(), includePinned: includePinned);
}
