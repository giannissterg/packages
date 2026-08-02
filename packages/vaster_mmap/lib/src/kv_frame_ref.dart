import 'dart:async';

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
