import 'dart:async';
import 'package:vaster_context/vaster_context.dart';
import 'allocation_strategy.dart';
import 'context_manager_interface.dart';

/// Standard single-heap implementation of [ContextManager].
class BasicContextManager implements ContextManager {
  final List<ContextSource> _sources = [];

  @override
  final ContextHeap heap = ContextHeap();

  AllocationStrategy allocationStrategy;

  BasicContextManager({
    List<ContextSource>? sources,
    this.allocationStrategy = const PriorityAllocationStrategy(),
  }) {
    if (sources != null) {
      _sources.addAll(sources);
    }
  }

  @override
  List<ContextSource> get sources => List.unmodifiable(_sources);

  @override
  void registerSource(ContextSource source) {
    _sources.removeWhere((s) => s.id == source.id);
    _sources.add(source);
  }

  @override
  bool unregisterSource(String id) {
    final count = _sources.length;
    _sources.removeWhere((s) => s.id == id);
    return _sources.length < count;
  }

  @override
  void pinRegion(String regionId) {
    final region = heap.regions.where((r) => r.id == regionId).firstOrNull;
    if (region != null) {
      heap.addRegion(region.copyWith(isPinned: true));
    }
  }

  @override
  void unpinRegion(String regionId) {
    final region = heap.regions.where((r) => r.id == regionId).firstOrNull;
    if (region != null) {
      heap.addRegion(region.copyWith(isPinned: false));
    }
  }

  @override
  Future<void> syncSources() async {
    for (final source in _sources) {
      final regions = await source.getRegions();
      heap.addAll(regions);
    }
  }

  @override
  Future<CompiledContext> compileContext({
    required TokenBudget budget,
  }) async {
    await syncSources();

    return allocationStrategy.allocate(
      regions: heap.regions,
      budget: budget,
    );
  }

  @override
  void pruneLifetimes(Set<ContextLifetime> expiredLifetimes) {
    for (final region in List<ContextRegion>.from(heap.regions)) {
      if (expiredLifetimes.contains(region.lifetime)) {
        heap.removeRegion(region.id);
      }
    }
  }
}
