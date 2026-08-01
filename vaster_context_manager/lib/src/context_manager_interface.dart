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

  /// Synchronizes all registered context sources into the active [heap].
  Future<void> syncSources();

  /// Compiles active context regions into a model-ready [CompiledContext] within [budget].
  Future<CompiledContext> compileContext({
    required TokenBudget budget,
  });

  /// Prunes expired context regions from the heap based on lifetime boundaries.
  void pruneLifetimes(Set<ContextLifetime> expiredLifetimes);
}
