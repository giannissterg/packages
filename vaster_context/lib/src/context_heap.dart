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

  /// Removes a region by ID.
  bool removeRegion(String id) {
    final before = _regions.length;
    _regions.removeWhere((r) => r.id == id);
    return _regions.length < before;
  }

  /// Clears all non-critical regions from the heap.
  void clearNonCritical() {
    _regions.removeWhere((r) => r.priority != ContextPriority.critical);
  }

  /// Clears all regions from the heap.
  void clear() {
    _regions.clear();
  }

  @override
  String toString() =>
      'ContextHeap(regions: ${_regions.length}, tokens: ~$totalEstimatedTokens)';
}
