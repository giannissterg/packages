/// Physical KV-state **contracts** — the backend-agnostic interface
/// between virtual context and physical LLM cache state.
///
/// [KvCacheHandle]s are physical frames; a [KvCacheController] is a
/// backend that materializes, restores, and evicts them. Two classes of
/// backend exist, declared via [KvCacheCapabilities]:
///  * **State-addressed** — local engines (llama.cpp) exposing real KV
///    tensor state: save, restore, evict as bytes.
///  * **Content-addressed** — hosted APIs (Claude `cache_control`, Gemini
///    `cachedContent`) where the physical cache is keyed by exact content
///    prefix and only reachable through request-shape hints.
///
/// Deliberately a leaf (rules.md Rule 6.15): this package knows nothing
/// of context regions or managers — the `ContextMmu` page table that
/// binds regions to handles lives in `vaster_context_mmu`, the one
/// component aware of both sides. Backend packages depend on these
/// contracts, never on the bridge. Leaf-ness is enforced by test.
library;

export 'src/in_memory_kv_cache_controller.dart';
export 'src/kv_cache_controller.dart';
export 'src/kv_cache_handle.dart';
