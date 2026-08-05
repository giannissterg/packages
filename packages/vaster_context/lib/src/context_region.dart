import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:vaster_model/vaster_model.dart';
import 'compression_info.dart';
import 'context_class.dart';
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

  /// Allocation class this region belongs to; null resolves to the class
  /// table's default class. Policy fields left null inherit from the class.
  final String? classId;

  /// Priority override for allocation and eviction; null = inherit from the
  /// region's [ContextClass] (the distinction between "unset" and "explicitly
  /// default" is what makes class inheritance implementable).
  final ContextPriority? priority;

  /// Lifetime override; null = inherit from the region's class.
  final ContextLifetime? lifetime;

  /// Whether this region is explicitly pinned (a runtime action, like mlock).
  /// A class's `pinnedByDefault` applies at allocation time and does not
  /// change this stored flag.
  final bool isPinned;

  /// Optional utility score (0.0 to 1.0) indicating relevance/recency.
  final double utility;

  /// Custom metadata tags.
  final Map<String, dynamic> metadata;

  /// Compressibility override; null = inherit from the region's class.
  final ContextCompressibility? compressibility;

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
    this.classId,
    this.priority,
    this.lifetime,
    this.isPinned = false,
    this.utility = 1.0,
    this.metadata = const {},
    this.compressibility,
    this.order = 0,
    this.compression,
  });

  /// Serializes the full region (checkpoint fidelity: every policy override,
  /// the null-vs-explicit distinction included via key omission).
  Map<String, dynamic> toJson() => {
        'id': id,
        'label': label,
        'messages': [for (final m in messages) m.toJson()],
        'estimatedTokens': estimatedTokens,
        if (classId != null) 'classId': classId,
        if (priority != null) 'priority': priority!.name,
        if (lifetime != null) 'lifetime': lifetime!.name,
        'isPinned': isPinned,
        'utility': utility,
        if (metadata.isNotEmpty) 'metadata': metadata,
        if (compressibility != null) 'compressibility': compressibility!.name,
        'order': order,
        if (compression != null) 'compression': compression!.toJson(),
      };

  factory ContextRegion.fromJson(Map<String, dynamic> json) => ContextRegion(
        id: json['id'] as String,
        label: json['label'] as String,
        messages: [
          for (final m in json['messages'] as List? ?? const [])
            ChatMessage.fromJson(Map<String, dynamic>.from(m as Map)),
        ],
        estimatedTokens: (json['estimatedTokens'] as num?)?.toInt() ?? 0,
        classId: json['classId'] as String?,
        priority: json['priority'] == null
            ? null
            : ContextPriority.values.byName(json['priority'] as String),
        lifetime: json['lifetime'] == null
            ? null
            : ContextLifetime.values.byName(json['lifetime'] as String),
        isPinned: json['isPinned'] as bool? ?? false,
        utility: (json['utility'] as num?)?.toDouble() ?? 1.0,
        metadata: json['metadata'] == null
            ? const {}
            : Map<String, dynamic>.from(json['metadata'] as Map),
        compressibility: json['compressibility'] == null
            ? null
            : ContextCompressibility.values
                .byName(json['compressibility'] as String),
        order: (json['order'] as num?)?.toInt() ?? 0,
        compression: json['compression'] == null
            ? null
            : CompressionInfo.fromJson(
                Map<String, dynamic>.from(json['compression'] as Map)),
      );

  // ── Policy resolution ────────────────────────────────────────────────────
  // Class-aware call sites resolve against the region's ContextClass; legacy
  // (class-unaware) call sites use the *OrDefault views, which reproduce the
  // pre-class defaults.

  /// Effective priority under [cls].
  ContextPriority effectivePriority(ContextClass cls) =>
      priority ?? cls.priority;

  /// Effective lifetime under [cls].
  ContextLifetime effectiveLifetime(ContextClass cls) =>
      lifetime ?? cls.lifetime;

  /// Effective compressibility under [cls].
  ContextCompressibility effectiveCompressibility(ContextClass cls) =>
      compressibility ?? cls.compressibility;

  /// Effective pinning under [cls]: explicit pin wins, else the class default.
  bool effectivePinned(ContextClass cls) => isPinned || cls.pinnedByDefault;

  /// Legacy default views for class-unaware call sites.
  ContextPriority get priorityOrDefault => priority ?? ContextPriority.medium;
  ContextLifetime get lifetimeOrDefault => lifetime ?? ContextLifetime.session;
  ContextCompressibility get compressibilityOrDefault =>
      compressibility ?? ContextCompressibility.none;

  /// Factory to construct a region from text content.
  factory ContextRegion.text({
    required String id,
    required String label,
    required Role role,
    required String text,
    int? estimatedTokens,
    String? classId,
    ContextPriority? priority,
    ContextLifetime? lifetime,
    bool isPinned = false,
    double utility = 1.0,
    Map<String, dynamic> metadata = const {},
    ContextCompressibility? compressibility,
    int order = 0,
  }) {
    final msg = ChatMessage(role: role, parts: [TextPart(text)]);
    final tokens = estimatedTokens ?? TokenEstimate.forText(text);
    return ContextRegion(
      id: id,
      label: label,
      messages: [msg],
      estimatedTokens: tokens,
      classId: classId,
      priority: priority,
      lifetime: lifetime,
      isPinned: isPinned,
      utility: utility,
      metadata: metadata,
      compressibility: compressibility,
      order: order,
    );
  }

  /// Note: for the nullable policy fields, `null` means "keep the current
  /// value" — copyWith cannot clear an override back to inherit.
  ContextRegion copyWith({
    String? id,
    String? label,
    List<ChatMessage>? messages,
    int? estimatedTokens,
    String? classId,
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
      classId: classId ?? this.classId,
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
      'ContextRegion(id: $id, label: "$label", tokens: ~$estimatedTokens, '
      'class: ${classId ?? '(default)'}, '
      'priority: ${priority?.name ?? 'inherit'}, pinned: $isPinned)';
}
