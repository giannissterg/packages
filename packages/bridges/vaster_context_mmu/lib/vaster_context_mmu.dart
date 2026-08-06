/// The bridge between virtual context and physical KV state.
///
/// Completes the virtual-memory metaphor: `ContextRegion`s are virtual
/// pages, `KvCacheHandle`s are physical frames, and the [ContextMmu] is
/// the page table mapping one onto the other through a backend
/// `KvCacheController`.
///
/// This package is deliberately the **only** component aware of both
/// sides (rules.md Rule 6.15): the KV contracts (`vaster_kv`) know
/// nothing of regions or context managers, and backend packages depend
/// on the contracts, never on this bridge. It is also the landing zone
/// for cache-aware context planning (roadmap goal C) — token-exact
/// prefix validation starts here.
library;

export 'src/context_mmu.dart';
