/// Physical context management for the Vaster LLM Virtual Machine.
///
/// Completes the virtual-memory metaphor: [ContextRegion]s are virtual pages,
/// [KvCacheHandle]s are physical frames, and the [ContextMmu] is the page
/// table mapping one onto the other through a backend [KvCacheController].
///
/// Two classes of physical backend exist, declared via [KvCacheCapabilities]:
///  * **State-addressed** — local engines (llama.cpp slots) exposing real KV
///    tensor state: save, restore, evict as bytes.
///  * **Content-addressed** — hosted APIs (Claude `cache_control`, Gemini
///    `cachedContent`) where the physical cache is keyed by exact content
///    prefix and only reachable through request-shape hints.
library;

export 'src/context_mmu.dart';
export 'src/in_memory_kv_cache_controller.dart';
export 'src/kv_cache_controller.dart';
export 'src/kv_cache_handle.dart';
