import 'package:vaster_context/vaster_context.dart';

/// Abstract interface class defining the contract for managing virtual context sources,
/// memory heaps, lifecycles, and model context compilation.
abstract interface class ContextManager {
  /// The active virtual context memory heap.
  ContextHeap get heap;

  /// Unmodifiable view of registered context sources.
  List<ContextSource> get sources;

  /// Registers a new [ContextSource].
  void registerSource(ContextSource source);

  /// Unregisters a [ContextSource] by ID.
  bool unregisterSource(String id);

  /// Pins a context region by ID to prevent anti-eviction during budget pressure.
  void pinRegion(String regionId);

  /// Unpins a context region by ID.
  void unpinRegion(String regionId);

  /// Returns a [ContextCacheDescriptor] for a pinned region, computing or retrieving
  /// its SHA-256 content fingerprint for JIT provider-side context caching.
  /// Returns null if [regionId] does not exist in the heap.
  ContextCacheDescriptor? getCacheDescriptor(String regionId);

  /// Returns cache descriptors for all currently pinned regions.
  List<ContextCacheDescriptor> getPinnedCacheDescriptors();

  /// Synchronizes all registered context sources into the active [heap].
  Future<void> syncSources();

  /// Compiles active context regions into a model-ready [CompiledContext] within [budget].
  Future<CompiledContext> compileContext({
    required TokenBudget budget,
  });

  /// Prunes expired context regions from the heap based on lifetime boundaries.
  void pruneLifetimes(Set<ContextLifetime> expiredLifetimes);
}
