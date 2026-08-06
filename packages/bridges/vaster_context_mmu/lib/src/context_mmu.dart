import 'package:vaster_context/vaster_context.dart';
import 'package:vaster_context_manager/vaster_context_manager.dart';
import 'package:vaster_model/vaster_model.dart';

import 'package:vaster_kv/vaster_kv.dart';

/// Statistics from an MMU binding pass — the page-table health of a run.
class MmuStats {
  /// Regions whose physical state was already materialized (page hits).
  int hits = 0;

  /// Regions that had to be materialized (page faults → prefill cost paid).
  int faults = 0;

  /// Stale mappings dropped because region content changed under the same id.
  int invalidations = 0;

  /// Tokens materialized by this pass's faults — the prefill cost paid
  /// now so later consumers restore instead of re-decoding.
  int tokensMaterialized = 0;

  @override
  String toString() => 'MmuStats(hits: $hits, faults: $faults, '
      'invalidations: $invalidations, '
      'tokensMaterialized: $tokensMaterialized)';
}

/// The Context Memory Management Unit: lowers Vaster's *virtual* context
/// (pinned [ContextRegion]s in a [ContextManager]'s heap) onto *physical*
/// LLM cache state through a [KvCacheController].
///
/// The mapping is a page table `regionId -> KvCacheHandle`, keyed by the
/// region's content fingerprint:
///
///  * **Page hit** — fingerprint unchanged and state materialized: reuse.
///  * **Page fault** — no physical state for the fingerprint: materialize
///    (pay the prefill once), then map.
///  * **Invalidation** — region content changed under the same id: evict the
///    stale frame and re-fault.
///
/// [bindPinnedRegions] returns [ContextCacheHint]s bound to live physical
/// handles — the same hints `ModelRequest.cacheHints` already carries, so
/// every backend consumes them uniformly: state-addressed backends restore
/// real KV bytes; content-addressed backends (hosted APIs) lower them to
/// prefix-cache markers.
class ContextMmu {
  final KvCacheController controller;

  /// Renders a region into the exact content that gets materialized —
  /// **the alignment contract hook**. The default, [regionContent], is
  /// the canonical fingerprint-derivation form. Backends whose prompt
  /// composition *renders* regions (e.g. the llama backend's
  /// `role: text` flattening) inject their own renderer so the
  /// materialized state is a token-exact prefix of the prompts it will
  /// be validated against. Fingerprints always key on the canonical
  /// content regardless — the renderer shapes the *payload*, never the
  /// page-table key (provenance addressing).
  final String Function(ContextRegion region) contentRenderer;

  /// Live page table: regionId -> physical handle.
  final Map<String, KvCacheHandle> _pageTable = {};

  ContextMmu({required this.controller, this.contentRenderer = regionContent});

  /// Read-only view of the current mappings.
  Map<String, KvCacheHandle> get pageTable => Map.unmodifiable(_pageTable);

  /// Walks the pinned regions of [contextManager], reconciles the page table
  /// against their current fingerprints, and returns cache hints bound to
  /// live physical state. [stats] (optional) accumulates hit/fault counts.
  Future<List<ContextCacheHint>> bindPinnedRegions(
    ContextManager contextManager, {
    MmuStats? stats,
  }) async {
    final hints = <ContextCacheHint>[];

    for (final descriptor in contextManager.getPinnedCacheDescriptors()) {
      final region = contextManager.heap.regions
          .where((r) => r.id == descriptor.regionId)
          .firstOrNull;
      if (region == null) continue;

      final mapped = _pageTable[descriptor.regionId];

      // Invalidation: same region id, different content.
      if (mapped != null &&
          mapped.contentFingerprint != descriptor.contentFingerprint) {
        await controller.evict(mapped);
        _pageTable.remove(descriptor.regionId);
        stats?.invalidations++;
      }

      // Resolve the physical frame: hit or fault.
      var handle = await controller.lookup(descriptor.contentFingerprint);
      if (handle != null) {
        stats?.hits++;
      } else {
        handle = await controller.materialize(
          contentFingerprint: descriptor.contentFingerprint,
          content: contentRenderer(region),
          tokenEstimate: region.estimatedTokens,
        );
        stats?.faults++;
        stats?.tokensMaterialized += handle.tokenCount;
      }
      _pageTable[descriptor.regionId] = handle;

      hints.add(ContextCacheHint(
        regionId: descriptor.regionId,
        contentFingerprint: descriptor.contentFingerprint,
        ttl: descriptor.ttl,
      ));
    }

    return hints;
  }

  /// Restores every mapped physical frame into the model context (used by
  /// state-addressed backends before generation). No-op for handles the
  /// controller no longer holds.
  Future<void> restoreAll() async {
    for (final handle in _pageTable.values) {
      try {
        await controller.restore(handle);
      } on StateError {
        // Frame was evicted underneath us; next bind will re-fault it.
      }
    }
  }

  /// Drops every mapping and frees the physical frames.
  Future<void> flush() async {
    for (final handle in _pageTable.values) {
      await controller.evict(handle);
    }
    _pageTable.clear();
  }

  /// Canonical region content — must match the fingerprint derivation used by
  /// the context manager ([ContextCacheDescriptor.fromContent] over newline-
  /// joined text parts).
  static String regionContent(ContextRegion region) => region.messages
      .expand((m) => m.parts)
      .map((p) => p is TextPart ? p.text : p.toString())
      .join('\n');
}
