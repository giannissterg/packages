import 'package:vaster_context_manager/vaster_context_manager.dart';
import 'package:vaster_model/vaster_model.dart';

/// Tracks JIT context cache hints accumulated during ISA execution.
///
/// When a [PinContextOp] is executed, [onRegionPinned] eagerly computes
/// the SHA-256 content fingerprint via [ContextManager.getCacheDescriptor]
/// and stores the result as a [ContextCacheHint]. All subsequent
/// [PromptOp] and [DispatchAgentTaskOp] calls read [activeHints] to
/// forward them to the active model provider.
///
/// This class owns all cache hint book-keeping, keeping [VasterRuntime]
/// free of fingerprinting logic.
class CacheHintTracker {
  final Map<String, ContextCacheHint> _hints = {};

  /// Unmodifiable list of currently tracked cache hints.
  List<ContextCacheHint> get activeHints => List.unmodifiable(_hints.values);

  /// Whether any hints are currently tracked.
  bool get isEmpty => _hints.isEmpty;

  /// Called when [PinContextOp] is executed for [regionId].
  ///
  /// Queries [contextManager] for the region's cache descriptor,
  /// computes / retrieves its SHA-256 fingerprint, and stores a
  /// [ContextCacheHint] for downstream prompt calls.
  void onRegionPinned(String regionId, ContextManager contextManager) {
    final descriptor = contextManager.getCacheDescriptor(regionId);
    if (descriptor != null && !descriptor.isExpired) {
      _hints[regionId] = ContextCacheHint(
        regionId: descriptor.regionId,
        contentFingerprint: descriptor.contentFingerprint,
        ttl: descriptor.ttl,
      );
    }
  }

  /// Removes the hint for [regionId] (e.g. when a region is unpinned).
  void removeHint(String regionId) => _hints.remove(regionId);

  /// Clears all tracked hints (e.g. on program start).
  void clear() => _hints.clear();
}
