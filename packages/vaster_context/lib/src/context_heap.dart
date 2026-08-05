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
  int get totalEstimatedTokens =>
      _regions.fold(0, (sum, r) => sum + r.estimatedTokens);

  /// Registers a region into the heap.
  ///
  /// NOTE: upsert-by-id that appends at the tail — re-adding an existing id
  /// *moves it to the end*. For in-place policy/content updates that must not
  /// reorder the heap, use [updateRegion] or [replaceRegion].
  void addRegion(ContextRegion region) {
    _regions.removeWhere((r) => r.id == region.id);
    _regions.add(region);
  }

  /// Registers multiple regions into the heap.
  void addAll(Iterable<ContextRegion> regions) {
    for (final r in regions) {
      addRegion(r);
    }
  }

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

  /// Replaces the region with the same id in place, or appends when absent.
  void replaceRegion(ContextRegion region) {
    if (!updateRegion(region.id, (_) => region)) {
      _regions.add(region);
    }
  }

  /// Source-sync upsert: merges [incoming] (fresh from a [ContextSource])
  /// with any existing heap region of the same id, preserving heap-side
  /// *policy* mutations (pin, priority, utility, compressibility overrides)
  /// and keeping compressed content ("shadow") as long as the incoming
  /// content still matches the compression's source fingerprint.
  void upsertFromSource(
    ContextRegion incoming, {
    required String Function(ContextRegion) fingerprintOf,
  }) {
    final existing = getRegion(incoming.id);
    if (existing == null) {
      _regions.add(incoming);
      return;
    }

    // A compressed region shadows its source while the source is unchanged.
    final compression = existing.compression;
    if (compression != null &&
        compression.sourceFingerprint == fingerprintOf(incoming)) {
      // Keep compressed content; refresh nothing.
      return;
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
  void clearNonCritical({bool force = false}) {
    _regions.removeWhere((r) =>
        r.priority != ContextPriority.critical && (force || !r.isPinned));
  }

  /// Clears all regions from the heap.
  void clear() {
    _regions.clear();
  }

  @override
  String toString() =>
      'ContextHeap(regions: ${_regions.length}, tokens: ~$totalEstimatedTokens)';
}
