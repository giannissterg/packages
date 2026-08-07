import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:vaster_kv/vaster_kv.dart';
import 'package:vaster_mmap/vaster_mmap.dart';
import 'package:vaster_token_estimate/vaster_token_estimate.dart';

/// A state-addressed [KvCacheController] whose physical frames live in named
/// POSIX shared-memory segments ([SharedMemoryFrame]).
///
/// Frame names are derived from content fingerprints, so discovery is
/// **cross-process**: a `lookup` that misses the local registry attempts to
/// attach the named segment — if a sibling VM or sidecar already materialized
/// that state, this controller maps the *same physical pages* (zero-copy) and
/// reports a hit. The [ContextMmu] then skips the prefill entirely.
///
/// What the frame *contains* is pluggable via [statePayloadBuilder]:
/// by default the canonical region content (UTF-8) — a transport payload a
/// sidecar prefills from — but it can be real KV tensor bytes produced by an
/// inference engine (e.g. read back from a llama.cpp slot file).
///
/// Also implements [KvFrameResolver], so an `MmapVasterModel` constructed
/// with this controller lowers cache hints to [KvFrameRef]s on the wire —
/// the sidecar receives frame *names*, not context bytes.
class MmapKvCacheController implements KvCacheController, KvFrameResolver {
  /// Prefix for shared-memory segment names.
  final String namePrefix;

  /// Produces the physical payload persisted for [materialize]d content.
  final FutureOr<Uint8List> Function(String content) statePayloadBuilder;

  /// fingerprint -> (handle, attached frame).
  final Map<String, (KvCacheHandle, SharedMemoryFrame)> _frames = {};

  MmapKvCacheController({
    this.namePrefix = 'vaster_kv_',
    FutureOr<Uint8List> Function(String content)? statePayloadBuilder,
  }) : statePayloadBuilder = statePayloadBuilder ?? ((content) => utf8.encode(content));

  @override
  KvCacheCapabilities get capabilities => const KvCacheCapabilities(
    isStateAddressed: true,
    supportsPersistence: true, // segments outlive the creating process
    supportsEviction: true,
  );

  @override
  String get backendId => 'mmap';

  String _segmentName(String fingerprint) => kvFrameName(prefix: namePrefix, fingerprint: fingerprint);

  KvCacheHandle _handleFor(String fingerprint, SharedMemoryFrame frame) => KvCacheHandle(
    handleId: frame.name,
    contentFingerprint: fingerprint,
    tokenCount: frame.meta,
    sizeBytes: frame.payloadLength,
    backend: backendId,
  );

  @override
  Future<KvCacheHandle?> lookup(String contentFingerprint) async {
    final local = _frames[contentFingerprint];
    if (local != null) return local.$1;

    // Cross-process discovery: another process may have materialized this
    // fingerprint — attach the named segment and share its physical pages.
    try {
      final frame = SharedMemoryFrame.attach(_segmentName(contentFingerprint));
      final handle = _handleFor(contentFingerprint, frame);
      _frames[contentFingerprint] = (handle, frame);
      return handle;
    } on StateError {
      return null;
    }
  }

  @override
  Future<KvCacheHandle> materialize({
    required String contentFingerprint,
    required String content,
    int? tokenEstimate,
  }) async {
    final existing = await lookup(contentFingerprint);
    if (existing != null) return existing;

    final payload = await statePayloadBuilder(content);
    final frame = SharedMemoryFrame.create(
      _segmentName(contentFingerprint),
      payload,
      meta: tokenEstimate ?? TokenEstimate.forText(content),
    );
    final handle = _handleFor(contentFingerprint, frame);
    _frames[contentFingerprint] = (handle, frame);
    return handle;
  }

  @override
  Future<bool> restore(KvCacheHandle handle) async {
    if (await lookup(handle.contentFingerprint) == null) {
      throw StateError('KV frame ${handle.handleId} is not materialized in shared memory.');
    }
    // Zero-copy: the state is already mapped — nothing MOVED, which is
    // exactly what the false receipt reports.
    return false;
  }

  /// Zero-copy view of a handle's physical state — backed directly by the
  /// shared pages, readable by every attached process.
  Uint8List readState(KvCacheHandle handle) {
    final frame = _frames[handle.contentFingerprint]?.$2;
    if (frame == null) {
      throw StateError('KV frame ${handle.handleId} is not attached.');
    }
    return frame.bytes;
  }

  @override
  Future<bool> evict(KvCacheHandle handle) async {
    final entry = _frames.remove(handle.contentFingerprint);
    entry?.$2.close(unlink: true);
    return entry != null;
  }

  @override
  Future<List<KvCacheHandle>> list() async => _frames.values.map((e) => e.$1).toList();

  /// [KvFrameResolver]: lowers a cache-hint fingerprint to a wire frame ref
  /// (cross-process discovery included via [lookup]'s attach fallback).
  @override
  Future<KvFrameRef?> resolveFrame(String contentFingerprint) async {
    final handle = await lookup(contentFingerprint);
    if (handle == null) return null;
    return KvFrameRef(
      frameName: handle.handleId,
      contentFingerprint: contentFingerprint,
      tokenCount: handle.tokenCount,
      sizeBytes: handle.sizeBytes,
    );
  }

  /// Detaches all frames without destroying the shared segments (other
  /// processes keep their mappings; state remains discoverable).
  /// Detaches every tracked frame; returns how many were closed.
  int detachAll() {
    final n = _frames.length;
    for (final entry in _frames.values) {
      entry.$2.close();
    }
    _frames.clear();
    return n;
  }
}
