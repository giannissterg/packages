/// A provider-agnostic JIT context cache hint attached to a [ModelRequest].
///
/// Contains the SHA-256 content fingerprint for a pinned context region so that
/// each [VasterModel] provider backend can translate this into its own native
/// caching handle (e.g. Gemini `cachedContent`, Anthropic cache-control headers,
/// or a local embedding cache key) without the runtime knowing anything about
/// provider internals.
class ContextCacheHint {
  /// Identifier of the pinned context region.
  final String regionId;

  /// SHA-256 hex fingerprint of the region's raw text content.
  final String contentFingerprint;

  /// Time-To-Live duration agreed upon at fingerprint creation time.
  final Duration ttl;

  const ContextCacheHint({
    required this.regionId,
    required this.contentFingerprint,
    this.ttl = const Duration(minutes: 60),
  });

  Map<String, dynamic> toJson() => {
        'regionId': regionId,
        'contentFingerprint': contentFingerprint,
        'ttlMs': ttl.inMilliseconds,
      };

  factory ContextCacheHint.fromJson(Map<String, dynamic> json) {
    return ContextCacheHint(
      regionId: json['regionId'] as String? ?? '',
      contentFingerprint: json['contentFingerprint'] as String? ?? '',
      ttl: Duration(milliseconds: json['ttlMs'] as int? ?? 3600000),
    );
  }

  @override
  String toString() =>
      'ContextCacheHint("$regionId" sha256:${contentFingerprint.length >= 8 ? contentFingerprint.substring(0, 8) : contentFingerprint})';
}
