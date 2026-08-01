import 'dart:async';
import 'package:vaster_context/vaster_context.dart';
import 'package:vaster_context_manager/vaster_context_manager.dart';
import 'package:vaster_model/vaster_model.dart';
import 'model_session_interface.dart';
import 'session_descriptor.dart';

/// Standard implementation of [ModelSession] supporting dynamic model switching per turn.
class BasicModelSession implements ModelSession {
  @override
  final SessionDescriptor descriptor;

  @override
  final VasterModel model;

  @override
  final ContextManager? contextManager;

  final List<ChatMessage> _history = [];

  BasicModelSession({
    required String sessionId,
    required this.model,
    this.contextManager,
    Map<String, dynamic> metadata = const {},
  }) : descriptor = SessionDescriptor(
          sessionId: sessionId,
          modelName: model.modelName,
          metadata: metadata,
        );

  @override
  String get sessionId => descriptor.sessionId;

  @override
  List<ChatMessage> get history => List.unmodifiable(_history);

  @override
  Future<ModelResponse> send(
    ChatMessage userMessage, {
    VasterModel? targetModel,
    GenerationConfig? config,
  }) async {
    final activeModel = targetModel ?? model;
    _history.add(userMessage);

    List<ChatMessage> compiledMessages = List.from(_history);
    ChatMessage? systemInstruction;

    if (contextManager != null) {
      final compiled = await contextManager!.compileContext(
        budget: TokenBudget(
          maxContextTokens: activeModel.capabilities.maxContextTokens,
          reservedOutputTokens: activeModel.capabilities.maxOutputTokens,
        ),
      );
      systemInstruction = compiled.systemInstruction;
      compiledMessages = [...compiled.messages, userMessage];
    }

    final request = ModelRequest(
      systemInstruction: systemInstruction,
      messages: compiledMessages,
      generationConfig: config ?? const GenerationConfig(),
    );

    final response = await activeModel.generate(request);
    _history.add(response.message);
    return response;
  }

  @override
  Stream<ModelResponseChunk> sendStream(
    ChatMessage userMessage, {
    VasterModel? targetModel,
    GenerationConfig? config,
  }) async* {
    final activeModel = targetModel ?? model;
    _history.add(userMessage);

    List<ChatMessage> compiledMessages = List.from(_history);
    ChatMessage? systemInstruction;

    if (contextManager != null) {
      final compiled = await contextManager!.compileContext(
        budget: TokenBudget(
          maxContextTokens: activeModel.capabilities.maxContextTokens,
          reservedOutputTokens: activeModel.capabilities.maxOutputTokens,
        ),
      );
      systemInstruction = compiled.systemInstruction;
      compiledMessages = [...compiled.messages, userMessage];
    }

    final request = ModelRequest(
      systemInstruction: systemInstruction,
      messages: compiledMessages,
      generationConfig: config ?? const GenerationConfig(),
    );

    final textBuffer = StringBuffer();
    final parts = <ContentPart>[];

    await for (final chunk in activeModel.generateStream(request)) {
      if (chunk.textDelta != null) {
        textBuffer.write(chunk.textDelta);
      }
      if (chunk.delta != null) {
        parts.add(chunk.delta!);
      }
      yield chunk;
    }

    final fullParts = parts.isNotEmpty ? parts : [TextPart(textBuffer.toString())];
    _history.add(ChatMessage(role: Role.model, parts: fullParts));
  }

  @override
  void clearHistory() {
    _history.clear();
  }
}
