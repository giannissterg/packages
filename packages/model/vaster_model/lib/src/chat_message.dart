import 'content_part.dart';
import 'role.dart';

/// Represents a single message turn in a conversation.
class ChatMessage {
  final Role role;
  final List<ContentPart> parts;
  final Map<String, dynamic> metadata;

  const ChatMessage({required this.role, required this.parts, this.metadata = const {}});

  /// Factory constructor for a user text message.
  factory ChatMessage.user(String text, {Map<String, dynamic> metadata = const {}}) =>
      ChatMessage(role: Role.user, parts: [TextPart(text)], metadata: metadata);

  /// Factory constructor for a model text output message.
  factory ChatMessage.model(String text, {Map<String, dynamic> metadata = const {}}) =>
      ChatMessage(role: Role.model, parts: [TextPart(text)], metadata: metadata);

  /// Factory constructor for a system instruction message.
  factory ChatMessage.system(String text, {Map<String, dynamic> metadata = const {}}) =>
      ChatMessage(role: Role.system, parts: [TextPart(text)], metadata: metadata);

  /// Factory constructor for a tool response message.
  factory ChatMessage.toolResponse(
    String callId,
    String name,
    Map<String, dynamic> response, {
    Map<String, dynamic> metadata = const {},
  }) => ChatMessage(
    role: Role.tool,
    parts: [FunctionResponsePart(callId: callId, name: name, response: response)],
    metadata: metadata,
  );

  /// Returns combined text content from all [TextPart] items in this message.
  String get text {
    return parts.whereType<TextPart>().map((p) => p.text).join('\n');
  }

  /// Returns all function call parts in this message.
  Iterable<FunctionCallPart> get functionCalls => parts.whereType<FunctionCallPart>();

  /// Returns all function response parts in this message.
  Iterable<FunctionResponsePart> get functionResponses => parts.whereType<FunctionResponsePart>();

  /// Returns all thought parts in this message.
  Iterable<ThoughtPart> get thoughts => parts.whereType<ThoughtPart>();

  Map<String, dynamic> toJson() => {
    'role': role.name,
    'parts': parts.map((p) => p.toJson()).toList(),
    if (metadata.isNotEmpty) 'metadata': metadata,
  };

  factory ChatMessage.fromJson(Map<String, dynamic> json) {
    final roleName = json['role'] as String? ?? 'user';
    final role = Role.values.firstWhere((r) => r.name == roleName, orElse: () => Role.user);
    final rawParts = json['parts'] as List? ?? [];
    final parts = rawParts.whereType<Map<String, dynamic>>().map((p) => ContentPart.fromJson(p)).toList();
    final metadata = Map<String, dynamic>.from(json['metadata'] as Map? ?? {});

    return ChatMessage(role: role, parts: parts, metadata: metadata);
  }

  ChatMessage copyWith({Role? role, List<ContentPart>? parts, Map<String, dynamic>? metadata}) {
    return ChatMessage(
      role: role ?? this.role,
      parts: parts ?? List.from(this.parts),
      metadata: metadata ?? Map.from(this.metadata),
    );
  }

  @override
  String toString() => 'ChatMessage(role: ${role.name}, parts: $parts)';
}
