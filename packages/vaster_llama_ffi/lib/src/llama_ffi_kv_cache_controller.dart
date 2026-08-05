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

  /// Frame-name prefix; the name is `prefix + first 16 fingerprint chars`
  /// (matching `MmapKvCacheController`'s convention).
  final String namePrefix;

  final Map<String, KvCacheHandle> _known = {};

  LlamaFfiKvCacheController(
      {required this.worker, this.namePrefix = 'vaster_kv_'});

  @override
  String get backendId => 'llama-ffi';

  @override
  KvCacheCapabilities get capabilities => const KvCacheCapabilities(
        isStateAddressed: true,
        supportsPersistence: true,
        supportsEviction: true,
      );

  String _frameName(String fingerprint) =>
      '$namePrefix${fingerprint.length > 16 ? fingerprint.substring(0, 16) : fingerprint}';

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

    await worker.reset();
    await worker.decodeText(content);
    final name = _frameName(contentFingerprint);
    final (sizeBytes, tokenCount) = await worker.exportStateToFrame(name);
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
