import 'context_priority.dart';
import 'context_region.dart';

/// Managed collection of virtual context regions (the "Virtual Context Memory Heap").
class ContextHeap {
  final List<ContextRegion> _regions = [];

  ContextHeap([List<ContextRegion>? initialRegions]) {
    if (initialRegions != null) {
      _regions.addAll(initialRegions);
    }
  }

  /// Unmodifiable view of active regions in the heap.
  List<ContextRegion> get regions => List.unmodifiable(_regions);

  /// Total estimated tokens consumed by all regions in this heap.
  int get totalEstimatedTokens => _regions.fold(0, (sum, r) => sum + r.estimatedTokens);

  /// Registers a region into the heap and returns the region it DISPLACED
  /// (same id), null when fresh — a silent overwrite is now observable
  /// (Rule 11).
  ///
  /// NOTE: upsert-by-id that appends at the tail — re-adding an existing id
  /// *moves it to the end*. For in-place policy/content updates that must not
  /// reorder the heap, use [updateRegion] or [replaceRegion].
  ContextRegion? addRegion(ContextRegion region) {
    final displaced = getRegion(region.id);
    _regions.removeWhere((r) => r.id == region.id);
    _regions.add(region);
    return displaced;
  }

  /// Registers multiple regions into the heap; returns the displaced ones.
  List<ContextRegion> addAll(Iterable<ContextRegion> regions) => [for (final r in regions) ?addRegion(r)];

  /// Returns the region with [id], or null.
  ContextRegion? getRegion(String id) {
    for (final region in _regions) {
      if (region.id == id) return region;
    }
    return null;
  }

  /// Applies [update] to the region with [id] **in place at its current
  /// index** — no reordering. Returns false when the id is absent.
  bool updateRegion(String id, ContextRegion Function(ContextRegion) update) {
    for (var i = 0; i < _regions.length; i++) {
      if (_regions[i].id == id) {
        _regions[i] = update(_regions[i]);
        return true;
      }
    }
    return false;
  }

  /// Replaces the region with the same id in place (or appends when
  /// absent) and returns the region it displaced, null when fresh.
  ContextRegion? replaceRegion(ContextRegion region) {
    final displaced = getRegion(region.id);
    if (!updateRegion(region.id, (_) => region)) {
      _regions.add(region);
    }
    return displaced;
  }

  /// Source-sync upsert: merges [incoming] (fresh from a [ContextSource])
  /// with any existing heap region of the same id, preserving heap-side
  /// *policy* mutations (pin, priority, utility, compressibility overrides)
  /// and keeping compressed content ("shadow") as long as the incoming
  /// content still matches the compression's source fingerprint.
  /// Returns the region now standing in the heap for [incoming.id] —
  /// the fresh insert, the still-shadowing compressed region, or the
  /// merged result (Rule 11: the caller sees what the sync produced).
  ContextRegion upsertFromSource(
    ContextRegion incoming, {
    required String Function(ContextRegion) fingerprintOf,
  }) {
    final existing = getRegion(incoming.id);
    if (existing == null) {
      _regions.add(incoming);
      return incoming;
    }

    // A compressed region shadows its source while the source is unchanged.
    final compression = existing.compression;
    if (compression != null && compression.sourceFingerprint == fingerprintOf(incoming)) {
      // Keep compressed content; refresh nothing.
      return existing;
    }

    // Source content wins; heap-side policy survives. (With nullable policy
    // fields, a heap-side null means "inherit" and correctly lets the
    // incoming source value — or class default — through.)
    updateRegion(
      incoming.id,
      (current) => incoming.copyWith(
        classId: current.classId,
        isPinned: current.isPinned,
        priority: current.priority,
        utility: current.utility,
        compressibility: current.compressibility,
        order: current.order != 0 ? current.order : incoming.order,
        clearCompression: true,
      ),
    );
    return getRegion(incoming.id)!;
  }

  /// Removes a region by ID. Pinned regions are protected: the call returns
  /// false and keeps the region unless [force] is set.
  bool removeRegion(String id, {bool force = false}) {
    final region = getRegion(id);
    if (region == null) return false;
    if (region.isPinned && !force) return false;
    _regions.removeWhere((r) => r.id == id);
    return true;
  }

  /// Clears all non-critical regions from the heap. Pinned regions are kept
  /// unless [force] is set.
  /// Returns the number of regions removed (Rule 11 — a sweep that
  /// removed nothing is observable).
  int clearNonCritical({bool force = false}) {
    final before = _regions.length;
    _regions.removeWhere((r) => r.priority != ContextPriority.critical && (force || !r.isPinned));
    return before - _regions.length;
  }

  /// Clears all regions from the heap; returns how many were dropped
  /// (Rule 11 — same idiom as [clearNonCritical] above it).
  int clear() {
    final dropped = _regions.length;
    _regions.clear();
    return dropped;
  }

  @override
  String toString() => 'ContextHeap(regions: ${_regions.length}, tokens: ~$totalEstimatedTokens)';
}
