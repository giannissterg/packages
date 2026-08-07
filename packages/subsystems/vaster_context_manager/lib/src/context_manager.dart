import 'dart:async';
import 'prune_report.dart';
import 'package:vaster_context/vaster_context.dart';
import 'package:vaster_events/vaster_events.dart';

import 'allocation_strategy.dart';
import 'class_aware_allocation_strategy.dart';
import 'compression/context_compactor.dart';
import 'compression/context_compressor.dart';
import 'context_manager_interface.dart';

/// Standard single-heap implementation of [ContextManager].
class BasicContextManager implements ContextManager {
  final List<ContextSource> _sources = [];

  /// In-process cache: regionId → ContextCacheDescriptor (keyed by content fingerprint).
  final Map<String, ContextCacheDescriptor> _cacheDescriptors = {};

  @override
  final ContextHeap heap = ContextHeap();

  /// The segment table governing class resolution for this manager.
  /// Replaced only at program load via [installClassTable] — never mutated
  /// mid-execution.
  ContextClassTable _classTable;

  @override
  ContextClassTable get classTable => _classTable;

  AllocationStrategy allocationStrategy;

  /// Registered compressors, strongest-preference first.
  final List<ContextCompressor> compressors;

  /// Optional event bus for eviction/compression telemetry.
  final RuntimeEventBus? eventBus;

  CompiledContext? _lastCompiled;

  BasicContextManager({
    List<ContextSource>? sources,
    ContextClassTable classTable = ContextClassTable.standard,
    AllocationStrategy? allocationStrategy,
    this.compressors = const [],
    this.eventBus,
  })  : _classTable = classTable,
        allocationStrategy = allocationStrategy ??
            ClassAwareAllocationStrategy(classTable: classTable) {
    if (sources != null) {
      _sources.addAll(sources);
    }
  }

  @override
  ContextClassTable installClassTable(ContextClassTable table) {
    final issues = table.validate();
    if (issues.isNotEmpty) {
      throw ArgumentError('Invalid context class table: ${issues.join('; ')}');
    }
    final displaced = _classTable;
    _classTable = table;
    // The default strategy is table-bound; rebind it. A custom strategy is
    // the caller's responsibility.
    if (allocationStrategy is ClassAwareAllocationStrategy) {
      allocationStrategy = ClassAwareAllocationStrategy(classTable: table);
    }
    return displaced;
  }

  // ── Region CRUD ────────────────────────────────────────────────────────

  @override
  List<ContextRegion> get regions => heap.regions;

  @override
  ContextRegion? getRegion(String regionId) => heap.getRegion(regionId);

  @override
  ContextRegion? addRegion(ContextRegion region) => heap.replaceRegion(region);

  @override
  bool removeRegion(String regionId, {bool force = false}) {
    final region = heap.getRegion(regionId);
    final removed = heap.removeRegion(regionId, force: force);
    if (removed) {
      _cacheDescriptors.remove(regionId);
      _emitEvicted([regionId], region?.estimatedTokens ?? 0, 'explicit');
    }
    return removed;
  }

  @override
  bool updateRegion(String regionId, ContextRegion Function(ContextRegion) update) =>
      heap.updateRegion(regionId, update);

  // ── Sources ────────────────────────────────────────────────────────────

  @override
  List<ContextSource> get sources => List.unmodifiable(_sources);

  @override
  ContextSource? registerSource(ContextSource source) {
    final displaced =
        _sources.where((s) => s.id == source.id).firstOrNull;
    _sources.removeWhere((s) => s.id == source.id);
    _sources.add(source);
    return displaced;
  }

  @override
  bool unregisterSource(String id) {
    final count = _sources.length;
    _sources.removeWhere((s) => s.id == id);
    return _sources.length < count;
  }

  // ── Pinning (in place — never reorders the heap) ───────────────────────

  @override
  ContextRegion? pinRegion(String regionId) {
    heap.updateRegion(regionId, (r) => r.copyWith(isPinned: true));
    return heap.getRegion(regionId);
  }

  @override
  ContextRegion? unpinRegion(String regionId) {
    heap.updateRegion(regionId, (r) => r.copyWith(isPinned: false));
    _cacheDescriptors.remove(regionId);
    return heap.getRegion(regionId);
  }

  // ── Cache descriptors (self-healing on content change) ─────────────────

  @override
  ContextCacheDescriptor? getCacheDescriptor(String regionId) {
    final region = heap.getRegion(regionId);
    if (region == null) return null;

    // Always derive the CURRENT fingerprint; reuse the cached descriptor only
    // when the content genuinely hasn't changed. Compression and in-place
    // updates therefore invalidate automatically.
    final currentFingerprint = regionFingerprintOf(region);
    final existing = _cacheDescriptors[regionId];
    if (existing != null &&
        existing.contentFingerprint == currentFingerprint &&
        !existing.isExpired) {
      return existing;
    }

    final descriptor = ContextCacheDescriptor.fromContent(
      regionId: regionId,
      rawContent: regionContentOf(region),
    );
    _cacheDescriptors[regionId] = descriptor;
    return descriptor;
  }

  @override
  List<ContextCacheDescriptor> getPinnedCacheDescriptors() {
    return heap.regions
        .where((r) => r.isPinned)
        .map((r) => getCacheDescriptor(r.id))
        .whereType<ContextCacheDescriptor>()
        .toList();
  }

  // ── Sync / compaction / compilation ────────────────────────────────────

  @override
  Future<int> syncSources() async {
    var synced = 0;
    for (final source in _sources) {
      final sourced = await source.getRegions();
      for (final region in sourced) {
        heap.upsertFromSource(region, fingerprintOf: regionFingerprintOf);
        synced++;
      }
    }
    return synced;
  }

  @override
  Future<CompactionReport> compact({
    required int targetTokens,
    String? regionId,
    bool includePinned = false,
  }) async {
    final compactor =
        ContextCompactor(compressors: compressors, classTable: _classTable);
    final report = await compactor.compact(
      regions: heap.regions,
      targetTokens: targetTokens,
      includePinned: includePinned,
      onlyRegionId: regionId,
      apply: (compressed) => heap.replaceRegion(compressed),
    );
    _emitCompressed(report);
    return report;
  }

  @override
  Future<CompiledContext> compileContext({
    required TokenBudget budget,
    bool allowCompression = true,
  }) async {
    await syncSources();

    // Compression pre-pass: shrink compressible regions before allocation
    // evicts anything. 90% target leaves headroom so allocation doesn't
    // immediately re-pressure.
    if (allowCompression &&
        compressors.isNotEmpty &&
        heap.totalEstimatedTokens > budget.availableInputBudget) {
      final report = await ContextCompactor(
              compressors: compressors, classTable: _classTable)
          .compact(
        regions: heap.regions,
        targetTokens: (budget.availableInputBudget * 0.9).floor(),
        apply: (compressed) => heap.replaceRegion(compressed),
      );
      _emitCompressed(report);
    }

    final compiled = allocationStrategy.allocate(
      regions: heap.regions,
      budget: budget,
    );
    _lastCompiled = compiled;

    if (compiled.evictedRegions.isNotEmpty) {
      _emitEvicted(
        compiled.evictedRegions.map((r) => r.id).toList(),
        compiled.evictedRegions.fold(0, (s, r) => s + r.estimatedTokens),
        'budget',
      );
    }
    return compiled;
  }

  @override
  CompiledContext? get lastCompiled => _lastCompiled;

  @override
  PruneReport pruneLifetimes(
      Set<ContextLifetime> expiredLifetimes,
      {bool force = false}) {
    final removedIds = <String>[];
    var tokensFreed = 0;
    for (final region in List<ContextRegion>.from(heap.regions)) {
      final effectiveLifetime =
          region.effectiveLifetime(_classTable.resolve(region.classId));
      if (!expiredLifetimes.contains(effectiveLifetime)) continue;
      // Sweeps respect pins and critical priority unless forced.
      if (!force &&
          (region.isPinned || region.priority == ContextPriority.critical)) {
        continue;
      }
      if (heap.removeRegion(region.id, force: true)) {
        _cacheDescriptors.remove(region.id);
        removedIds.add(region.id);
        tokensFreed += region.estimatedTokens;
      }
    }
    if (removedIds.isNotEmpty) {
      _emitEvicted(removedIds, tokensFreed, 'lifetime');
    }
    return PruneReport(prunedIds: removedIds, tokensFreed: tokensFreed);
  }

  // ── Telemetry ──────────────────────────────────────────────────────────

  int _eventCounter = 0;
  String _nextEventId(String kind) =>
      'ctx_${kind}_${DateTime.now().microsecondsSinceEpoch}_${_eventCounter++}';

  /// Returns the published event's id, null when no bus is wired.
  String? _emitEvicted(List<String> regionIds, int tokensFreed, String reason) {
    // Resolve classes before publishing — the regions may already be gone
    // from the heap by the time a subscriber looks.
    final classes = <String, String>{
      for (final id in regionIds)
        id: _classTable.resolve(heap.getRegion(id)?.classId).name,
    };
    return eventBus?.publish(ContextEvictedEvent(
      eventId: _nextEventId('evict'),
      evictedRegionIds: regionIds,
      tokensFreed: tokensFreed,
      metadata: {'reason': reason, 'classes': classes},
    ));
  }

  void _emitCompressed(CompactionReport report) {
    final bus = eventBus;
    if (bus == null) return;
    for (final entry in report.entries) {
      bus.publish(ContextCompressedEvent(
        eventId: _nextEventId('compress'),
        regionId: entry.regionId,
        tokensBefore: entry.tokensBefore,
        tokensAfter: entry.tokensAfter,
        compressorId: entry.compressorId,
        lossy: entry.lossy,
      ));
    }
  }
}
