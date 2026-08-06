/// Zero-copy shared-memory KV cache controller for Vaster.
///
/// Physical context frames live in named POSIX shared-memory segments
/// ([SharedMemoryFrame]), so materialized KV state is shared across processes
/// — a VM process pages state in once, and any sidecar or sibling VM that
/// knows the fingerprint attaches to the same physical pages without copying.
library;

export 'src/mmap_kv_cache_controller.dart';
