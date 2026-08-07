/// An opaque reference to materialized physical LLM context state —
/// the "physical frame" of Vaster's virtual-context memory model.
///
/// For state-addressed backends (llama.cpp) a handle names real KV tensor
/// bytes (a saved slot file). For content-addressed backends (hosted APIs)
/// it names a server-side prefix-cache entry reachable only by resending the
/// exact content with a cache marker.
class KvCacheHandle {
  /// Backend-scoped identifier (e.g. a slot filename or cache key).
  final String handleId;

  /// SHA-256 fingerprint of the source content this state was computed from.
  final String contentFingerprint;

  /// Number of prompt tokens materialized into this state, when known.
  final int tokenCount;

  /// Physical size of the cached state in bytes, when known (state-addressed
  /// backends only — hosted caches never disclose this).
  final int? sizeBytes;

  /// Identifier of the backend that owns this handle.
  final String backend;

  /// When the physical state was materialized.
  final DateTime createdAt;

  KvCacheHandle({
    required this.handleId,
    required this.contentFingerprint,
    this.tokenCount = 0,
    this.sizeBytes,
    required this.backend,
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now();

  Map<String, dynamic> toJson() => {
    'handleId': handleId,
    'contentFingerprint': contentFingerprint,
    'tokenCount': tokenCount,
    if (sizeBytes != null) 'sizeBytes': sizeBytes,
    'backend': backend,
    'createdAt': createdAt.toIso8601String(),
  };

  factory KvCacheHandle.fromJson(Map<String, dynamic> json) => KvCacheHandle(
    handleId: json['handleId'] as String? ?? '',
    contentFingerprint: json['contentFingerprint'] as String? ?? '',
    tokenCount: json['tokenCount'] as int? ?? 0,
    sizeBytes: json['sizeBytes'] as int?,
    backend: json['backend'] as String? ?? 'unknown',
    createdAt: DateTime.tryParse(json['createdAt'] as String? ?? ''),
  );

  @override
  String toString() =>
      'KvCacheHandle($handleId, fp:${contentFingerprint.length >= 8 ? contentFingerprint.substring(0, 8) : contentFingerprint}, '
      '$tokenCount tok, backend:$backend)';
}

/// What a physical cache backend can actually do — so the [ContextMmu] never
/// promises semantics the hardware can't deliver.
class KvCacheCapabilities {
  /// True when handles reference real KV tensor state (save/restore of bytes).
  /// False for hosted prefix caches, where "restore" means re-sending the
  /// exact content with a cache marker.
  final bool isStateAddressed;

  /// Whether materialized state survives process/server restarts.
  final bool supportsPersistence;

  /// Whether the backend can explicitly evict state.
  final bool supportsEviction;

  /// Maximum number of simultaneously materialized handles (null = unbounded).
  final int? maxSlots;

  const KvCacheCapabilities({
    required this.isStateAddressed,
    this.supportsPersistence = false,
    this.supportsEviction = true,
    this.maxSlots,
  });
}
