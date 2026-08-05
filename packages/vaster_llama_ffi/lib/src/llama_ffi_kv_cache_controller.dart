import 'package:vaster_kv/vaster_kv.dart';
import 'package:vaster_mmap/vaster_mmap.dart';

import 'llama_worker.dart';

/// [KvCacheController] whose physical frames are **real KV tensor state in
/// shared memory** — the zero-copy backend.
///
/// `materialize` prefills the content in the worker's engine and exports
/// sequence state *directly into* a content-addressed
/// [SharedMemoryFrame]'s mapped pages; `restore` hands an attached frame's
/// pages straight back to the engine. State crosses process boundaries as
/// shared pages: any Vaster process (or a later run of the same pipeline)
/// that computes the same content fingerprint discovers the frame by name
/// and resumes without re-decoding the prefix.
///
/// Discovery is cross-process by construction — [lookup] falls back to a
/// named-segment attach, the same path a foreign process takes.
///
/// Also a [KvFrameResolver]: ring-transport clients ([MmapVasterModel])
/// lower cache hints to [KvFrameRef]s through [resolveFrame] so only the
/// frame *name* crosses the ring, never the content.
final class LlamaFfiKvCacheController
    implements KvCacheController, KvFrameResolver {
  final LlamaWorker worker;

  /// Frame-name prefix, fed through [kvFrameName] (the convention's one
  /// home in `vaster_mmap`). The default is distinct from raw-content
  /// controllers' `vaster_kv_` — these frames hold llama engine *state*,
  /// and the payload kind is part of the naming contract. Ring-transport
  /// clients resolving against this controller's frames must use the
  /// same prefix.
  final String namePrefix;

  final Map<String, KvCacheHandle> _known = {};

  LlamaFfiKvCacheController(
      {required this.worker, this.namePrefix = 'vaster_kv_llama_'});

  @override
  String get backendId => 'llama-ffi';

  @override
  KvCacheCapabilities get capabilities => const KvCacheCapabilities(
        isStateAddressed: true,
        supportsPersistence: true,
        supportsEviction: true,
      );

  String _frameName(String fingerprint) =>
      kvFrameName(prefix: namePrefix, fingerprint: fingerprint);

  @override
  Future<KvCacheHandle?> lookup(String contentFingerprint) async {
    final local = _known[contentFingerprint];
    if (local != null) return local;
    // Cross-process discovery: a peer (or a previous process) may have
    // materialized this fingerprint — probe the named segment.
    final name = _frameName(contentFingerprint);
    final SharedMemoryFrame frame;
    try {
      frame = SharedMemoryFrame.attach(name);
    } on StateError {
      return null;
    }
    final handle = KvCacheHandle(
      handleId: name,
      contentFingerprint: contentFingerprint,
      tokenCount: frame.meta,
      sizeBytes: frame.payloadLength,
      backend: backendId,
    );
    frame.close(unlink: false);
    _known[contentFingerprint] = handle;
    return handle;
  }

  @override
  Future<KvCacheHandle> materialize({
    required String contentFingerprint,
    required String content,
    int? tokenEstimate,
  }) async {
    final existing = await lookup(contentFingerprint);
    if (existing != null) return existing;

    // One atomic worker op — reset, decode, export cannot interleave
    // with a generate (a poisoned frame would persist cross-process).
    final name = _frameName(contentFingerprint);
    final (sizeBytes, tokenCount) =
        await worker.materializeToFrame(content: content, frameName: name);
    final handle = KvCacheHandle(
      handleId: name,
      contentFingerprint: contentFingerprint,
      tokenCount: tokenCount,
      sizeBytes: sizeBytes,
      backend: backendId,
    );
    _known[contentFingerprint] = handle;
    return handle;
  }

  @override
  Future<void> restore(KvCacheHandle handle) =>
      worker.importStateFromFrame(_frameName(handle.contentFingerprint));

  @override
  Future<void> evict(KvCacheHandle handle) async {
    _known.remove(handle.contentFingerprint);
    try {
      SharedMemoryFrame.attach(_frameName(handle.contentFingerprint))
          .close(unlink: true);
    } on StateError {
      // Already gone — eviction is idempotent.
    }
  }

  @override
  Future<List<KvCacheHandle>> list() async => _known.values.toList();

  @override
  Future<KvFrameRef?> resolveFrame(String contentFingerprint) async {
    final handle = await lookup(contentFingerprint);
    if (handle == null) return null;
    return KvFrameRef(
      frameName: _frameName(contentFingerprint),
      contentFingerprint: contentFingerprint,
      tokenCount: handle.tokenCount,
    );
  }
}
