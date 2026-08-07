import 'dart:async';

import 'package:vaster_context/vaster_context.dart';
import 'package:vaster_context_manager/vaster_context_manager.dart';
import 'package:vaster_model/vaster_model.dart';

import 'model_session_interface.dart';
import 'session_descriptor.dart';
import 'session_history_source.dart';

/// Standard implementation of [ModelSession] supporting dynamic model switching and thread forking.
///
/// Conversation history is projected into the [contextManager]'s heap via a
/// [SessionHistorySource], so it is budgeted, compressible, prioritized, and
/// inspectable like every other context region. The prompt sent to the model
/// is exactly `compileContext(...).messages` — history is never concatenated
/// separately.
class BasicModelSession implements ModelSession {
  @override
  final SessionDescriptor descriptor;

  @override
  final VasterModel model;

  @override
  final ContextManager contextManager;

  final List<ChatMessage> _history = [];

  BasicModelSession({
    required String sessionId,
    required this.model,
    required this.contextManager,
    List<ChatMessage> initialHistory = const [],
    Map<String, dynamic> metadata = const {},
  }) : descriptor = SessionDescriptor(sessionId: sessionId, modelName: model.modelName, metadata: metadata) {
    if (initialHistory.isNotEmpty) {
      _history.addAll(initialHistory);
    }
    contextManager.registerSource(
      SessionHistorySource(sessionId: sessionId, historyProvider: () => _history),
    );
  }

  @override
  String get sessionId => descriptor.sessionId;

  @override
  List<ChatMessage> get history => List.unmodifiable(_history);

  @override
  Future<ModelResponse> send(
    ChatMessage userMessage, {
    VasterModel? targetModel,
    GenerationConfig? config,
    CancellationToken? cancelToken,
    List<ContextCacheHint> cacheHints = const [],
  }) async {
    cancelToken?.throwIfCancelled();

    final activeModel = targetModel ?? model;
    _history.add(userMessage);

    // The user message is already in _history, so the history tail region
    // carries it — compiled.messages IS the complete prompt. Appending it
    // again would double-send.
    final compiled = await contextManager.compileContext(
      budget: TokenBudget(
        maxContextTokens: activeModel.capabilities.maxContextTokens,
        reservedOutputTokens: activeModel.capabilities.maxOutputTokens,
        // Sessions attach no tool definitions to the request.
        reservedToolTokens: 0,
      ),
    );

    cancelToken?.throwIfCancelled();

    final request = ModelRequest(
      systemInstruction: compiled.systemInstruction,
      messages: compiled.messages,
      generationConfig: config ?? const GenerationConfig(),
      cancelToken: cancelToken,
      cacheHints: cacheHints,
    );

    final response = await activeModel.generate(request);
    _history.add(response.message);
    // Turn boundary: expire ephemeral-lifetime scratch regions.
    contextManager.pruneLifetimes({ContextLifetime.ephemeral});
    return response;
  }

  /// Sessions own no resource trackers (they are conversational memory, not
  /// meters — Rule 6.4): token/cost metering for streams happens at the VM
  /// funnel (`VasterVMEngine.promptStream`), not here.
  @override
  Stream<ModelResponseChunk> sendStream(
    ChatMessage userMessage, {
    VasterModel? targetModel,
    GenerationConfig? config,
    CancellationToken? cancelToken,
    List<ContextCacheHint> cacheHints = const [],
  }) async* {
    cancelToken?.throwIfCancelled();

    final activeModel = targetModel ?? model;
    _history.add(userMessage);

    // History (including the just-added user message) arrives via the heap.
    final compiled = await contextManager.compileContext(
      budget: TokenBudget(
        maxContextTokens: activeModel.capabilities.maxContextTokens,
        reservedOutputTokens: activeModel.capabilities.maxOutputTokens,
        reservedToolTokens: 0,
      ),
    );

    final request = ModelRequest(
      systemInstruction: compiled.systemInstruction,
      messages: compiled.messages,
      generationConfig: config ?? const GenerationConfig(),
      cancelToken: cancelToken,
      cacheHints: cacheHints,
    );

    final textBuffer = StringBuffer();
    final parts = <ContentPart>[];

    await for (final chunk in activeModel.generateStream(request)) {
      cancelToken?.throwIfCancelled();
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
    contextManager.pruneLifetimes({ContextLifetime.ephemeral});
  }

  /// Forks the session. By default the fork SHARES this session's
  /// [contextManager] (both histories project into one heap and share its
  /// budget); pass a fresh [contextManager] to isolate the fork.
  @override
  ModelSession fork({String? newSessionId, ContextManager? contextManager}) {
    final forkId = newSessionId ?? '${sessionId}_fork_${DateTime.now().millisecondsSinceEpoch}';
    return BasicModelSession(
      sessionId: forkId,
      model: model,
      contextManager: contextManager ?? this.contextManager,
      initialHistory: List.from(_history),
    );
  }

  @override
  void appendMessage(ChatMessage message) => _history.add(message);

  @override
  int clearHistory() {
    final dropped = _history.length;
    _history.clear();
    // Remove projected history regions so the heap doesn't serve stale turns.
    for (final region in List<ContextRegion>.from(contextManager.regions)) {
      if (region.id.startsWith('session:$sessionId:history')) {
        contextManager.removeRegion(region.id, force: true);
      }
    }
    return dropped;
  }
}
