import 'package:vaster_kv/vaster_kv.dart';
import 'package:vaster_mmap/vaster_mmap.dart';

import 'llama_worker.dart';

const _imageCodec = KvStateImageCodec();

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
final class LlamaFfiKvCacheController implements KvCacheController, KvFrameResolver {
  final LlamaWorker worker;

  /// Frame-name prefix, fed through [kvFrameName] (the convention's one
  /// home in `vaster_mmap`). The default is distinct from raw-content
  /// controllers' `vaster_kv_` — these frames hold llama engine *state*,
  /// and the payload kind is part of the naming contract. The engine's
  /// tag (hex) is appended to the prefix, so every producer gets its own
  /// namespace: two models materializing the same content cannot collide,
  /// and a format migration cannot leave a stale frame squatting on a
  /// name this producer will look up. Ring-transport clients resolving
  /// against this controller's frames must use the same prefix.
  final String namePrefix;

  final Map<String, KvCacheHandle> _known = {};
  String? _producerPrefix;

  LlamaFfiKvCacheController({required this.worker, this.namePrefix = 'vaster_kv_llama_'});

  @override
  String get backendId => 'llama-ffi';

  @override
  KvCacheCapabilities get capabilities =>
      const KvCacheCapabilities(isStateAddressed: true, supportsPersistence: true, supportsEviction: true);

  Future<String> _frameName(String fingerprint) async {
    final producer = _producerPrefix ??= '$namePrefix${(await worker.engineTag()).toRadixString(16)}_';
    return kvFrameName(prefix: producer, fingerprint: fingerprint);
  }

  @override
  Future<KvCacheHandle?> lookup(String contentFingerprint) async {
    final local = _known[contentFingerprint];
    if (local != null) return local;
    // Cross-process discovery: a peer (or a previous process) may have
    // materialized this fingerprint — probe the named segment. A hit is
    // only a hit if the payload parses as a valid KvStateImage: an
    // unparseable squatter (e.g. a pre-format frame) is unlinked so the
    // name can be re-materialized — otherwise discovery would report a
    // frame that every consumer rejects, blocking reuse forever.
    final name = await _frameName(contentFingerprint);
    final SharedMemoryFrame frame;
    try {
      frame = SharedMemoryFrame.attach(name);
    } on StateError {
      return null;
    }
    final KvStateImage image;
    try {
      image = _imageCodec.parse(frame.bytes);
    } on KvStateImageFormatException {
      frame.close(unlink: true); // reclaim the name from the squatter
      return null;
    } on KvStateImageAlignmentException {
      frame.close(unlink: true);
      return null;
    }
    final handle = KvCacheHandle(
      handleId: name,
      contentFingerprint: contentFingerprint,
      tokenCount: image.tokenCount,
      sizeBytes: image.lengthInBytes,
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

    // One atomic worker op — reset, decode, publish cannot interleave
    // with a generate (a poisoned frame would persist cross-process).
    // The frame's payload is a KvStateImage carrying the validation
    // provenance (token ids, engineTag, fingerprint).
    final name = await _frameName(contentFingerprint);
    final (sizeBytes, tokenCount) = await worker.materializeToFrame(
      content: content,
      contentFingerprint: contentFingerprint,
      frameName: name,
    );
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
  Future<bool> restore(KvCacheHandle handle) async {
    await worker.importStateFromFrame(await _frameName(handle.contentFingerprint));
    return true; // real engine state moved frame → context
  }

  @override
  Future<bool> evict(KvCacheHandle handle) async {
    final known = _known.remove(handle.contentFingerprint) != null;
    try {
      SharedMemoryFrame.attach(await _frameName(handle.contentFingerprint)).close(unlink: true);
      return true;
    } on StateError {
      // Already gone — eviction is idempotent.
      return known;
    }
  }

  @override
  Future<List<KvCacheHandle>> list() async => _known.values.toList();

  @override
  Future<KvFrameRef?> resolveFrame(String contentFingerprint) async {
    final handle = await lookup(contentFingerprint);
    if (handle == null) return null;
    return KvFrameRef(
      frameName: await _frameName(contentFingerprint),
      contentFingerprint: contentFingerprint,
      tokenCount: handle.tokenCount,
    );
  }
}
