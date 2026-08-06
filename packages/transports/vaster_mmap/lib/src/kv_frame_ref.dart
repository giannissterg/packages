import 'dart:async';

/// **The one home of the KV frame-name convention** (rules.md Rule 1/9):
/// a frame's segment name is `prefix` + the first 16 fingerprint
/// characters. Every KV controller derives names through this function —
/// never inline — so producers and cross-process discoverers cannot
/// drift.
///
/// Prefixes are **per payload producer**: raw-content frames
/// (`vaster_kv_`) and engine-state frames (e.g. `vaster_kv_llama_`) must
/// use distinct prefixes, because the payload *kind* is part of the
/// contract — a text frame squatting on a state frame's name would make
/// discovery lie about what is restorable.
String kvFrameName({required String prefix, required String fingerprint}) =>
    '$prefix${fingerprint.length > 16 ? fingerprint.substring(0, 16) : fingerprint}';

/// A wire reference to a materialized [SharedMemoryFrame] — what crosses the
/// IPC ring *instead of* the context bytes themselves.
///
/// The sidecar attaches the named segment and prefills from the mapped pages
/// directly: the bulk context never travels through the ring.
class KvFrameRef {
  /// Shared-memory segment name to attach (e.g. `vaster_kv_1124a401bda83283`).
  final String frameName;

  /// SHA-256 fingerprint of the content the frame was materialized from.
  final String contentFingerprint;

  /// Token count of the frame's content, when known.
  final int tokenCount;

  /// Physical payload size in bytes, when known.
  final int? sizeBytes;

  const KvFrameRef({
    required this.frameName,
    required this.contentFingerprint,
    this.tokenCount = 0,
    this.sizeBytes,
  });

  Map<String, dynamic> toJson() => {
        'frameName': frameName,
        'contentFingerprint': contentFingerprint,
        'tokenCount': tokenCount,
        if (sizeBytes != null) 'sizeBytes': sizeBytes,
      };

  factory KvFrameRef.fromJson(Map<String, dynamic> json) => KvFrameRef(
        frameName: json['frameName'] as String? ?? '',
        contentFingerprint: json['contentFingerprint'] as String? ?? '',
        tokenCount: json['tokenCount'] as int? ?? 0,
        sizeBytes: json['sizeBytes'] as int?,
      );

  @override
  String toString() => 'KvFrameRef($frameName, $tokenCount tok)';
}

/// Resolves content fingerprints to live shared-memory frame references.
///
/// Implemented by `MmapKvCacheController` (in `vaster_kv_mmap`); accepted by
/// [MmapVasterModel] so cache hints lower to frame refs on the wire.
abstract interface class KvFrameResolver {
  FutureOr<KvFrameRef?> resolveFrame(String contentFingerprint);
}
