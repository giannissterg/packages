import 'package:vaster_context/vaster_context.dart';

import 'compression/context_compactor.dart';

/// Abstract interface class defining the contract for managing virtual context sources,
/// memory heaps, lifecycles, and model context compilation.
abstract interface class ContextManager {
  /// The segment table governing class resolution for this manager.
  ContextClassTable get classTable;

  /// Installs a program-declared class table (at program load — class tables
  /// are static metadata, never mutated mid-execution).
  /// Returns the table it displaced (Rule 11).
  ContextClassTable installClassTable(ContextClassTable table);

  /// The active virtual context memory heap.
  ///
  /// NOTE: on composite managers this is a merged *snapshot* — mutations are
  /// lost. Prefer the region-level methods below, which route correctly on
  /// every implementation.
  ContextHeap get heap;

  /// Read-only view of all active regions (merged across children on
  /// composite managers).
  List<ContextRegion> get regions;

  /// Returns the region with [regionId], or null.
  ContextRegion? getRegion(String regionId);

  /// Adds (or replaces, same id in place) a region.
  /// Returns the same-id region it displaced, null when fresh.
  ContextRegion? addRegion(ContextRegion region);

  /// Removes a region. Pinned regions are protected unless [force].
  /// Returns whether a region was removed.
  bool removeRegion(String regionId, {bool force = false});

  /// Applies [update] to the region in place (no reordering).
  /// Returns false when the id is absent.
  bool updateRegion(String regionId, ContextRegion Function(ContextRegion) update);

  /// Unmodifiable view of registered context sources.
  List<ContextSource> get sources;

  /// Registers a new [ContextSource].
  /// Returns the same-id source it displaced, null when fresh.
  ContextSource? registerSource(ContextSource source);

  /// Unregisters a [ContextSource] by ID.
  bool unregisterSource(String id);

  /// Pins a context region by ID to prevent anti-eviction during budget pressure.
  /// Returns the region as pinned, null when [regionId] is absent —
  /// pinning nothing is observable (Rule 11).
  ContextRegion? pinRegion(String regionId);

  /// Unpins a context region by ID.
  /// Returns the region as unpinned, null when absent.
  ContextRegion? unpinRegion(String regionId);

  /// Returns a [ContextCacheDescriptor] for a region, computing or retrieving
  /// its SHA-256 content fingerprint for JIT provider-side context caching.
  /// Returns null if [regionId] does not exist in the heap.
  ContextCacheDescriptor? getCacheDescriptor(String regionId);

  /// Returns cache descriptors for all currently pinned regions.
  List<ContextCacheDescriptor> getPinnedCacheDescriptors();

  /// Synchronizes all registered context sources into the active [heap].
  /// Returns the number of source regions upserted into the heap.
  Future<int> syncSources();

  /// Compresses regions toward [targetTokens] total using the registered
  /// compressors. [regionId] targets a single region; [includePinned] allows
  /// compressing pinned regions (their cache fingerprints will change).
  Future<CompactionReport> compact({
    required int targetTokens,
    String? regionId,
    bool includePinned = false,
  });

  /// Compiles active context regions into a model-ready [CompiledContext]
  /// within [budget]. When over budget and [allowCompression] is set, an
  /// async compression pre-pass shrinks compressible regions before the
  /// allocation strategy runs.
  Future<CompiledContext> compileContext({
    required TokenBudget budget,
    bool allowCompression = true,
  });

  /// The most recent [compileContext] result, for inspection.
  CompiledContext? get lastCompiled;

  /// Prunes expired context regions from the heap based on lifetime
  /// boundaries. Pinned and critical regions are kept unless [force].
  /// Returns what the sweep freed — ids and tokens; an empty report is
  /// an observable "pruned nothing".
  ({List<String> prunedIds, int tokensFreed}) pruneLifetimes(
      Set<ContextLifetime> expiredLifetimes,
      {bool force = false});
}
