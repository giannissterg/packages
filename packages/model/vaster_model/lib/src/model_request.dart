import 'cancellation_token.dart';
import 'chat_message.dart';
import 'context_cache_hint.dart';
import 'generation_config.dart';
import 'tool_definition.dart';

/// Request parameter object sent to a [VasterModel].
class ModelRequest {
  /// Optional system instruction guiding model behavior.
  final ChatMessage? systemInstruction;

  /// Ordered list of conversation turn messages.
  final List<ChatMessage> messages;

  /// Available tool / function declarations accessible by the model.
  final List<ToolDefinition> tools;

  /// Parameter configuration (temperature, topP, maxTokens, etc.).
  final GenerationConfig generationConfig;

  /// Optional cancellation token handle.
  final CancellationToken? cancelToken;

  /// Optional arbitrary metadata attached to this request context.
  final Map<String, dynamic> metadata;

  /// Optional JIT context cache hints for pinned regions.
  /// Each hint carries a content fingerprint that a [VasterModel] provider
  /// can translate to its native caching handle (e.g. Gemini `cachedContent`).
  final List<ContextCacheHint> cacheHints;

  const ModelRequest({
    required this.messages,
    this.systemInstruction,
    this.tools = const [],
    this.generationConfig = const GenerationConfig(),
    this.cancelToken,
    this.metadata = const {},
    this.cacheHints = const [],
  });

  Map<String, dynamic> toJson() => {
        if (systemInstruction != null)
          'systemInstruction': systemInstruction!.toJson(),
        'messages': messages.map((m) => m.toJson()).toList(),
        if (tools.isNotEmpty) 'tools': tools.map((t) => t.toJson()).toList(),
        'generationConfig': generationConfig.toJson(),
        if (metadata.isNotEmpty) 'metadata': metadata,
        if (cacheHints.isNotEmpty)
          'cacheHints': cacheHints.map((h) => h.toJson()).toList(),
      };

  factory ModelRequest.fromJson(Map<String, dynamic> json) {
    final sysRaw = json['systemInstruction'] as Map<String, dynamic>?;
    final msgsRaw = json['messages'] as List? ?? [];
    final toolsRaw = json['tools'] as List? ?? [];
    final genRaw = json['generationConfig'] as Map<String, dynamic>?;

    return ModelRequest(
      systemInstruction:
          sysRaw != null ? ChatMessage.fromJson(sysRaw) : null,
      messages: msgsRaw
          .whereType<Map<String, dynamic>>()
          .map((m) => ChatMessage.fromJson(m))
          .toList(),
      tools: toolsRaw
          .whereType<Map<String, dynamic>>()
          .map((t) => ToolDefinition.fromJson(t))
          .toList(),
      generationConfig: genRaw != null
          ? GenerationConfig.fromJson(genRaw)
          : const GenerationConfig(),
      metadata: Map<String, dynamic>.from(json['metadata'] as Map? ?? {}),
      cacheHints: (json['cacheHints'] as List? ?? [])
          .whereType<Map<String, dynamic>>()
          .map((h) => ContextCacheHint.fromJson(h))
          .toList(),
    );
  }

  ModelRequest copyWith({
    ChatMessage? systemInstruction,
    List<ChatMessage>? messages,
    List<ToolDefinition>? tools,
    GenerationConfig? generationConfig,
    CancellationToken? cancelToken,
    Map<String, dynamic>? metadata,
    List<ContextCacheHint>? cacheHints,
  }) {
    return ModelRequest(
      systemInstruction: systemInstruction ?? this.systemInstruction,
      messages: messages ?? List.from(this.messages),
      tools: tools ?? List.from(this.tools),
      generationConfig: generationConfig ?? this.generationConfig,
      cancelToken: cancelToken ?? this.cancelToken,
      metadata: metadata ?? Map.from(this.metadata),
      cacheHints: cacheHints ?? List.from(this.cacheHints),
    );
  }
}
