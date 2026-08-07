import 'dart:async';
import 'prune_report.dart';
import 'package:vaster_context/vaster_context.dart';

import 'allocation_strategy.dart';
import 'class_aware_allocation_strategy.dart';
import 'compression/context_compactor.dart';
import 'compression/context_compressor.dart';
import 'context_manager_interface.dart';

/// A composite implementation of [ContextManager] that combines multiple child
/// context managers into a single unified context management engine.
///
/// Region-level operations route to the **owning child** (the first child
/// whose heap holds the region); additions go to the first child.
class CompositeContextManager implements ContextManager {
  final List<ContextManager> children;
  AllocationStrategy allocationStrategy;

  /// Compressors used for composite-level compaction. When empty, children's
  /// own compaction can still be invoked individually.
  final List<ContextCompressor> compressors;

  CompiledContext? _lastCompiled;

  CompositeContextManager({
    this.children = const [],
    AllocationStrategy? allocationStrategy,
    ContextClassTable classTable = ContextClassTable.standard,
    this.compressors = const [],
  })  : _classTable = classTable,
        allocationStrategy = allocationStrategy ??
            ClassAwareAllocationStrategy(classTable: classTable);

  ContextClassTable _classTable;

  @override
  ContextClassTable get classTable => _classTable;

  @override
  ContextClassTable installClassTable(ContextClassTable table) {
    final displaced = _classTable;
    _classTable = table;
    if (allocationStrategy is ClassAwareAllocationStrategy) {
      allocationStrategy = ClassAwareAllocationStrategy(classTable: table);
    }
    for (final child in children) {
      child.installClassTable(table);
    }
    return displaced;
  }

  /// A merged **snapshot** of all children's regions. Mutating this heap has
  /// no effect on any child — use the region-level methods instead.
  @Deprecated('Snapshot only; mutations are lost. '
      'Use regions/getRegion/addRegion/removeRegion/updateRegion.')
  @override
  ContextHeap get heap {
    final mergedHeap = ContextHeap();
    for (final child in children) {
      mergedHeap.addAll(child.regions);
    }
    return mergedHeap;
  }

  @override
  List<ContextRegion> get regions =>
      [for (final child in children) ...child.regions];

  ContextManager? _ownerOf(String regionId) {
    for (final child in children) {
      if (child.getRegion(regionId) != null) return child;
    }
    return null;
  }

  @override
  ContextRegion? getRegion(String regionId) =>
      _ownerOf(regionId)?.getRegion(regionId);

  @override
  ContextRegion? addRegion(ContextRegion region) {
    final owner = _ownerOf(region.id);
    if (owner != null) {
      return owner.addRegion(region);
    }
    if (children.isEmpty) {
      throw StateError(
          'Cannot add region: CompositeContextManager has no children.');
    }
    return children.first.addRegion(region);
  }

  @override
  bool removeRegion(String regionId, {bool force = false}) =>
      _ownerOf(regionId)?.removeRegion(regionId, force: force) ?? false;

  @override
  bool updateRegion(
          String regionId, ContextRegion Function(ContextRegion) update) =>
      _ownerOf(regionId)?.updateRegion(regionId, update) ?? false;

  @override
  List<ContextSource> get sources {
    final allSources = <ContextSource>[];
    for (final child in children) {
      allSources.addAll(child.sources);
    }
    return List.unmodifiable(allSources);
  }

  @override
  ContextSource? registerSource(ContextSource source) {
    if (children.isEmpty) {
      throw StateError(
          'Cannot register source: CompositeContextManager has no children.');
    }
    return children.first.registerSource(source);
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
  ContextRegion? pinRegion(String regionId) =>
      _ownerOf(regionId)?.pinRegion(regionId);

  @override
  ContextRegion? unpinRegion(String regionId) =>
      _ownerOf(regionId)?.unpinRegion(regionId);

  @override
  ContextCacheDescriptor? getCacheDescriptor(String regionId) =>
      _ownerOf(regionId)?.getCacheDescriptor(regionId);

  @override
  List<ContextCacheDescriptor> getPinnedCacheDescriptors() {
    final seen = <String>{};
    final descriptors = <ContextCacheDescriptor>[];
    for (final child in children) {
      for (final d in child.getPinnedCacheDescriptors()) {
        if (seen.add(d.regionId)) descriptors.add(d);
      }
    }
    return descriptors;
  }

  @override
  Future<int> syncSources() async {
    final counts =
        await Future.wait(children.map((child) => child.syncSources()));
    return counts.fold<int>(0, (sum, n) => sum + n);
  }

  @override
  Future<CompactionReport> compact({
    required int targetTokens,
    String? regionId,
    bool includePinned = false,
  }) async {
    final compactor =
        ContextCompactor(compressors: compressors, classTable: _classTable);
    // apply routes each compressed region back to the child that owns it —
    // mutations land in real heaps, not the throwaway merge.
    return compactor.compact(
      regions: regions,
      targetTokens: targetTokens,
      includePinned: includePinned,
      onlyRegionId: regionId,
      apply: (compressed) {
        _ownerOf(compressed.id)?.updateRegion(compressed.id, (_) => compressed);
      },
    );
  }

  @override
  Future<CompiledContext> compileContext({
    required TokenBudget budget,
    bool allowCompression = true,
  }) async {
    await syncSources();

    if (allowCompression &&
        compressors.isNotEmpty &&
        regions.fold(0, (s, r) => s + r.estimatedTokens) >
            budget.availableInputBudget) {
      await compact(targetTokens: (budget.availableInputBudget * 0.9).floor());
    }

    final compiled = allocationStrategy.allocate(
      regions: regions,
      budget: budget,
    );
    _lastCompiled = compiled;
    return compiled;
  }

  @override
  CompiledContext? get lastCompiled => _lastCompiled;

  @override
  PruneReport pruneLifetimes(Set<ContextLifetime> expiredLifetimes,
          {bool force = false}) =>
      // The monoid does the merging — no hand-rolled accumulation.
      children.fold(
          PruneReport.empty,
          (acc, child) =>
              acc + child.pruneLifetimes(expiredLifetimes, force: force));
}
