import 'package:vaster_model/vaster_model.dart';
import 'context_lifetime.dart';
import 'context_priority.dart';

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

  /// Optional utility score (0.0 to 1.0) indicating relevance/recency.
  final double utility;

  /// Custom metadata tags.
  final Map<String, dynamic> metadata;

  const ContextRegion({
    required this.id,
    required this.label,
    required this.messages,
    required this.estimatedTokens,
    this.priority = ContextPriority.medium,
    this.lifetime = ContextLifetime.session,
    this.utility = 1.0,
    this.metadata = const {},
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
    double utility = 1.0,
    Map<String, dynamic> metadata = const {},
  }) {
    final msg = ChatMessage(role: role, parts: [TextPart(text)]);
    final tokens = estimatedTokens ?? (text.length / 4).ceil();
    return ContextRegion(
      id: id,
      label: label,
      messages: [msg],
      estimatedTokens: tokens,
      priority: priority,
      lifetime: lifetime,
      utility: utility,
      metadata: metadata,
    );
  }

  ContextRegion copyWith({
    String? id,
    String? label,
    List<ChatMessage>? messages,
    int? estimatedTokens,
    ContextPriority? priority,
    ContextLifetime? lifetime,
    double? utility,
    Map<String, dynamic>? metadata,
  }) {
    return ContextRegion(
      id: id ?? this.id,
      label: label ?? this.label,
      messages: messages ?? List.from(this.messages),
      estimatedTokens: estimatedTokens ?? this.estimatedTokens,
      priority: priority ?? this.priority,
      lifetime: lifetime ?? this.lifetime,
      utility: utility ?? this.utility,
      metadata: metadata ?? Map.from(this.metadata),
    );
  }

  @override
  String toString() =>
      'ContextRegion(id: $id, label: "$label", tokens: ~$estimatedTokens, priority: ${priority.name})';
}
