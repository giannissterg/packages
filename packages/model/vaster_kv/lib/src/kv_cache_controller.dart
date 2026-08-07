import 'kv_cache_handle.dart';

/// Backend interface over physical LLM context state — the "memory controller"
/// the [ContextMmu] pages against.
abstract interface class KvCacheController {
  /// What this backend can physically do.
  KvCacheCapabilities get capabilities;

  /// Backend identifier stamped onto handles (e.g. `llama_cpp`, `in_memory`).
  String get backendId;

  /// Returns the live handle for [contentFingerprint], or null if the state
  /// is not currently materialized.
  Future<KvCacheHandle?> lookup(String contentFingerprint);

  /// Materializes physical state for [content] (prefill + save) and returns
  /// its handle. Idempotent per fingerprint: re-materializing existing state
  /// returns the live handle.
  Future<KvCacheHandle> materialize({
    required String contentFingerprint,
    required String content,
    int? tokenEstimate,
  });

  /// Loads [handle]'s state into the active model context so the next
  /// generation starts from it. Returns true when state really moved,
  /// false when the call was a no-op — for content-addressed backends
  /// the "restore" happens via request-shape cache markers, and a
  /// silent no-op is exactly what the sibling [evict]'s Rule 11 receipt
  /// was added to expose.
  Future<bool> restore(KvCacheHandle handle);

  /// Releases [handle]'s physical state.
  /// Returns true when [handle] was present and evicted, false when it
  /// was unknown — a no-op eviction is observable (Rule 11).
  Future<bool> evict(KvCacheHandle handle);

  /// All currently materialized handles.
  Future<List<KvCacheHandle>> list();
}
