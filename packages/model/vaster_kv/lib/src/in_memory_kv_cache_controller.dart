import 'dart:convert';

import 'kv_cache_controller.dart';
import 'kv_cache_handle.dart';
import 'package:vaster_token_estimate/vaster_token_estimate.dart';

/// In-process simulation of a state-addressed KV cache — LRU-evicting slot
/// store used for tests and for modeling physical-context behavior without a
/// local inference engine.
class InMemoryKvCacheController implements KvCacheController {
  final int? maxSlots;

  /// fingerprint -> (handle, simulated state bytes), in LRU order
  /// (first = least recently used).
  final Map<String, (KvCacheHandle, List<int>)> _slots = {};

  int materializations = 0;
  int restores = 0;
  int evictions = 0;

  InMemoryKvCacheController({this.maxSlots});

  @override
  KvCacheCapabilities get capabilities => KvCacheCapabilities(
        isStateAddressed: true,
        supportsPersistence: false,
        supportsEviction: true,
        maxSlots: maxSlots,
      );

  @override
  String get backendId => 'in_memory';

  @override
  Future<KvCacheHandle?> lookup(String contentFingerprint) async {
    final slot = _slots.remove(contentFingerprint);
    if (slot == null) return null;
    _slots[contentFingerprint] = slot; // refresh LRU position
    return slot.$1;
  }

  @override
  Future<KvCacheHandle> materialize({
    required String contentFingerprint,
    required String content,
    int? tokenEstimate,
  }) async {
    final existing = await lookup(contentFingerprint);
    if (existing != null) return existing;

    // LRU eviction under slot pressure.
    while (maxSlots != null && _slots.length >= maxSlots!) {
      final oldest = _slots.keys.first;
      await evict(_slots[oldest]!.$1);
    }

    materializations++;
    final state = utf8.encode(content); // simulated KV tensor bytes
    final handle = KvCacheHandle(
      handleId: 'slot_${contentFingerprint.substring(0, 12)}',
      contentFingerprint: contentFingerprint,
      tokenCount: tokenEstimate ?? TokenEstimate.forText(content),
      sizeBytes: state.length,
      backend: backendId,
    );
    _slots[contentFingerprint] = (handle, state);
    return handle;
  }

  @override
  Future<void> restore(KvCacheHandle handle) async {
    if (!_slots.containsKey(handle.contentFingerprint)) {
      throw StateError('KV state for ${handle.handleId} is not materialized.');
    }
    restores++;
  }

  @override
  Future<bool> evict(KvCacheHandle handle) async {
    if (_slots.remove(handle.contentFingerprint) != null) {
      evictions++;
      return true;
    }
    return false;
  }

  @override
  Future<List<KvCacheHandle>> list() async =>
      _slots.values.map((s) => s.$1).toList();
}
