import 'package:vaster_model/vaster_model.dart';

/// Serialization helpers for converting [ModelRequest], [ModelResponse], and
/// [ModelResponseChunk] payloads to/from Unix Domain Socket JSON transport maps.
abstract final class UnixSocketProtocol {
  /// Converts a [ModelRequest] to a JSON-serializable Map.
  static Map<String, dynamic> requestToJson(String command, ModelRequest request, {String? requestId}) {
    return {
      'command': command,
      if (requestId != null) 'requestId': requestId,
      'systemInstruction': request.systemInstruction?.text,
      'messages': request.messages
          .map((m) => {
                'role': m.role.name,
                'text': m.text,
              })
          .toList(),
      'tools': request.tools.map((t) => t.toJson()).toList(),
      'config': {
        'temperature': request.generationConfig.temperature,
        'topP': request.generationConfig.topP,
        'maxOutputTokens': request.generationConfig.maxOutputTokens,
        'stopSequences': request.generationConfig.stopSequences,
      },
    };
  }

  /// Parses a [ModelRequest] from a Unix socket JSON Map.
  static ModelRequest requestFromJson(Map<String, dynamic> json) {
    final sysText = json['systemInstruction'] as String?;
    final sysInst = sysText != null && sysText.isNotEmpty ? ChatMessage.system(sysText) : null;

    final messagesRaw = json['messages'] as List? ?? [];
    final messages = messagesRaw.map((m) {
      final map = m as Map<String, dynamic>;
      final roleStr = map['role'] as String? ?? 'user';
      final role = Role.values.firstWhere(
        (r) => r.name == roleStr,
        orElse: () => Role.user,
      );
      return ChatMessage(role: role, parts: [TextPart(map['text'] as String? ?? '')]);
    }).toList();

    final toolsRaw = json['tools'] as List? ?? [];
    final tools = toolsRaw
        .map((t) => ToolDefinition.fromJson(Map<String, dynamic>.from(t as Map)))
        .toList();

    final cfgMap = json['config'] as Map<String, dynamic>? ?? {};
    final config = GenerationConfig(
      temperature: (cfgMap['temperature'] as num?)?.toDouble(),
      topP: (cfgMap['topP'] as num?)?.toDouble(),
      maxOutputTokens: cfgMap['maxOutputTokens'] as int?,
      stopSequences: (cfgMap['stopSequences'] as List?)?.cast<String>(),
    );

    return ModelRequest(
      systemInstruction: sysInst,
      messages: messages,
      tools: tools,
      generationConfig: config,
    );
  }

  /// Converts a [ModelResponse] to a JSON-serializable Map.
  static Map<String, dynamic> responseToJson(ModelResponse response, {String? requestId}) {
    return {
      'status': 'ok',
      if (requestId != null) 'requestId': requestId,
      'text': response.text,
      'finishReason': response.finishReason.name,
      'usage': {
        'promptTokenCount': response.usage.promptTokenCount,
        'candidatesTokenCount': response.usage.candidatesTokenCount,
        'totalTokenCount': response.usage.totalTokenCount,
      },
      'functionCalls': response.functionCalls
          .map((c) => {
                'callId': c.callId,
                'name': c.name,
                'arguments': c.arguments,
              })
          .toList(),
    };
  }

  /// Parses a [ModelResponse] from a Unix socket JSON Map.
  static ModelResponse responseFromJson(Map<String, dynamic> json) {
    final text = json['text'] as String? ?? '';
    final finishStr = json['finishReason'] as String? ?? 'stop';
    final finishReason = FinishReason.values.firstWhere(
      (f) => f.name == finishStr,
      orElse: () => FinishReason.stop,
    );

    final usageMap = json['usage'] as Map<String, dynamic>? ?? {};
    final usage = UsageMetadata(
      promptTokenCount: usageMap['promptTokenCount'] as int? ?? 0,
      candidatesTokenCount: usageMap['candidatesTokenCount'] as int? ?? 0,
      totalTokenCount: usageMap['totalTokenCount'] as int? ?? 0,
    );

    final fnCallsRaw = json['functionCalls'] as List? ?? [];
    final functionCalls = fnCallsRaw.map((c) {
      final map = c as Map<String, dynamic>;
      return FunctionCallPart(
        callId: map['callId'] as String? ?? 'call_0',
        name: map['name'] as String? ?? '',
        arguments: Map<String, dynamic>.from(map['arguments'] as Map? ?? {}),
      );
    }).toList();

    final parts = <ContentPart>[
      if (text.isNotEmpty) TextPart(text),
      ...functionCalls,
    ];

    return ModelResponse(
      message: ChatMessage(role: Role.model, parts: parts),
      finishReason: finishReason,
      usage: usage,
      rawResponse: json,
    );
  }
}
