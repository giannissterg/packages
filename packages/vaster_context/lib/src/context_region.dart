import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:vaster_model/vaster_model.dart';
import 'compression_info.dart';
import 'context_compressibility.dart';
import 'context_lifetime.dart';
import 'context_priority.dart';
import 'package:vaster_token_estimate/vaster_token_estimate.dart';

/// Canonical textual content of a region — the single source of truth for
/// content fingerprints (newline-joined text parts). Used by cache
/// descriptors, the KV MMU, and source-sync shadowing; all three MUST agree.
String regionContentOf(ContextRegion region) => region.messages
    .expand((m) => m.parts)
    .map((p) => p is TextPart ? p.text : p.toString())
    .join('\n');

/// Canonical SHA-256 hex fingerprint of a region's content.
String regionFingerprintOf(ContextRegion region) =>
    sha256.convert(utf8.encode(regionContentOf(region))).toString();

/// A discrete region of virtual context inside the [ContextHeap].
class ContextRegion {
  /// Unique identifier of this region.
  final String id;

  /// Human-readable label or description of region content.
  final String label;

  /// List of chat messages in this region.
  final List<ChatMessage> messages;

  /// Estimated token usage of this region.
  final int estimatedTokens;

  /// Priority of this region for token allocation and eviction.
  final ContextPriority priority;

  /// Lifetime boundary of this context region.
  final ContextLifetime lifetime;

  /// Whether this region is pinned to prevent anti-eviction during budget pressure.
  final bool isPinned;

  /// Optional utility score (0.0 to 1.0) indicating relevance/recency.
  final double utility;

  /// Custom metadata tags.
  final Map<String, dynamic> metadata;

  /// The strongest transformation this region may undergo under budget
  /// pressure. Defaults to [ContextCompressibility.none] (never altered).
  final ContextCompressibility compressibility;

  /// Flattening sequence hint: allocation *selection* is priority-driven, but
  /// included regions render into messages sorted by [order] (stable).
  /// Default 0 preserves legacy ordering; history chunks use large values so
  /// conversation turns always render chronologically last.
  final int order;

  /// Compression provenance — null when the region has never been compressed.
  final CompressionInfo? compression;

  /// Whether this region currently holds compressed content.
  bool get isCompressed => compression != null;

  const ContextRegion({
    required this.id,
    required this.label,
    required this.messages,
    required this.estimatedTokens,
    this.priority = ContextPriority.medium,
    this.lifetime = ContextLifetime.session,
    this.isPinned = false,
    this.utility = 1.0,
    this.metadata = const {},
    this.compressibility = ContextCompressibility.none,
    this.order = 0,
    this.compression,
  });

  /// Factory to construct a region from text content.
  factory ContextRegion.text({
    required String id,
    required String label,
    required Role role,
    required String text,
    int? estimatedTokens,
    ContextPriority priority = ContextPriority.medium,
    ContextLifetime lifetime = ContextLifetime.session,
    bool isPinned = false,
    double utility = 1.0,
    Map<String, dynamic> metadata = const {},
    ContextCompressibility compressibility = ContextCompressibility.none,
    int order = 0,
  }) {
    final msg = ChatMessage(role: role, parts: [TextPart(text)]);
    final tokens = estimatedTokens ?? TokenEstimate.forText(text);
    return ContextRegion(
      id: id,
      label: label,
      messages: [msg],
      estimatedTokens: tokens,
      priority: priority,
      lifetime: lifetime,
      isPinned: isPinned,
      utility: utility,
      metadata: metadata,
      compressibility: compressibility,
      order: order,
    );
  }

  ContextRegion copyWith({
    String? id,
    String? label,
    List<ChatMessage>? messages,
    int? estimatedTokens,
    ContextPriority? priority,
    ContextLifetime? lifetime,
    bool? isPinned,
    double? utility,
    Map<String, dynamic>? metadata,
    ContextCompressibility? compressibility,
    int? order,
    CompressionInfo? compression,
    bool clearCompression = false,
  }) {
    return ContextRegion(
      id: id ?? this.id,
      label: label ?? this.label,
      messages: messages ?? List.from(this.messages),
      estimatedTokens: estimatedTokens ?? this.estimatedTokens,
      priority: priority ?? this.priority,
      lifetime: lifetime ?? this.lifetime,
      isPinned: isPinned ?? this.isPinned,
      utility: utility ?? this.utility,
      metadata: metadata ?? Map.from(this.metadata),
      compressibility: compressibility ?? this.compressibility,
      order: order ?? this.order,
      compression: clearCompression ? null : (compression ?? this.compression),
    );
  }

  @override
  String toString() =>
      'ContextRegion(id: $id, label: "$label", tokens: ~$estimatedTokens, priority: ${priority.name}, pinned: $isPinned)';
}
