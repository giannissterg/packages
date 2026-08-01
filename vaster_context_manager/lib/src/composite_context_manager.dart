import 'dart:async';
import 'package:vaster_context/vaster_context.dart';
import 'allocation_strategy.dart';
import 'context_manager_interface.dart';

/// A composite implementation of [ContextManager] that combines multiple child
/// context managers into a single unified context management engine.
class CompositeContextManager implements ContextManager {
  final List<ContextManager> children;
  AllocationStrategy allocationStrategy;

  CompositeContextManager({
    this.children = const [],
    this.allocationStrategy = const PriorityAllocationStrategy(),
  });

  @override
  ContextHeap get heap {
    final mergedHeap = ContextHeap();
    for (final child in children) {
      mergedHeap.addAll(child.heap.regions);
    }
    return mergedHeap;
  }

  @override
  List<ContextSource> get sources {
    final allSources = <ContextSource>[];
    for (final child in children) {
      allSources.addAll(child.sources);
    }
    return List.unmodifiable(allSources);
  }

  @override
  void registerSource(ContextSource source) {
    if (children.isNotEmpty) {
      children.first.registerSource(source);
    } else {
      throw StateError('Cannot register source: CompositeContextManager has no children.');
    }
  }

  @override
  bool unregisterSource(String id) {
    var removed = false;
    for (final child in children) {
      if (child.unregisterSource(id)) {
        removed = true;
      }
    }
    return removed;
  }

  @override
  Future<void> syncSources() async {
    await Future.wait(children.map((child) => child.syncSources()));
  }

  @override
  Future<CompiledContext> compileContext({
    required TokenBudget budget,
  }) async {
    await syncSources();

    final allRegions = <ContextRegion>[];
    for (final child in children) {
      allRegions.addAll(child.heap.regions);
    }

    return allocationStrategy.allocate(
      regions: allRegions,
      budget: budget,
    );
  }

  @override
  void pruneLifetimes(Set<ContextLifetime> expiredLifetimes) {
    for (final child in children) {
      child.pruneLifetimes(expiredLifetimes);
    }
  }
}
