import 'package:crypto/crypto.dart';

import 'dart:convert';

/// Content-addressable cache descriptor for JIT Context Caching.
///
/// Produced by [ContextManager] when context regions are pinned, enabling
/// LLM model providers to reuse remote cache handles (e.g. Gemini `cachedContent`
/// or Anthropic prompt caching headers) for zero-latency, zero-cost token replay.
class ContextCacheDescriptor {
  final String regionId;
  final String contentFingerprint;
  final Duration ttl;
  final DateTime createdAt;

  ContextCacheDescriptor({
    required this.regionId,
    required this.contentFingerprint,
    this.ttl = const Duration(minutes: 60),
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now();

  /// Computes a SHA-256 fingerprint for [rawContent].
  factory ContextCacheDescriptor.fromContent({
    required String regionId,
    required String rawContent,
    Duration ttl = const Duration(minutes: 60),
  }) {
    final bytes = utf8.encode(rawContent);
    final digest = sha256.convert(bytes);
    return ContextCacheDescriptor(regionId: regionId, contentFingerprint: digest.toString(), ttl: ttl);
  }

  /// Whether this cache descriptor has exceeded its Time-To-Live.
  bool get isExpired => DateTime.now().difference(createdAt) > ttl;

  Map<String, dynamic> toJson() => {
    'regionId': regionId,
    'contentFingerprint': contentFingerprint,
    'ttlMs': ttl.inMilliseconds,
    'createdAt': createdAt.toIso8601String(),
  };

  factory ContextCacheDescriptor.fromJson(Map<String, dynamic> json) {
    return ContextCacheDescriptor(
      regionId: json['regionId'] as String? ?? '',
      contentFingerprint: json['contentFingerprint'] as String? ?? '',
      ttl: Duration(milliseconds: json['ttlMs'] as int? ?? 3600000),
      createdAt: DateTime.tryParse(json['createdAt'] as String? ?? '') ?? DateTime.now(),
    );
  }

  @override
  String toString() => 'ContextCacheDescriptor("$regionId" sha256:${contentFingerprint.substring(0, 8)})';
}
