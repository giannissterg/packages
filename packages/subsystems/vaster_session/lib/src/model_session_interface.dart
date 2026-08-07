import 'package:vaster_context_manager/vaster_context_manager.dart';
import 'package:vaster_model/vaster_model.dart';
import 'session_descriptor.dart';

/// Interface representing an active interactive session binding a [VasterModel],
/// optional [ContextManager], and an ordered list of conversation [ChatMessage] turns.
abstract interface class ModelSession {
  /// Session handle descriptor.
  SessionDescriptor get descriptor;

  /// Unique session identifier.
  String get sessionId => descriptor.sessionId;

  /// The default model backend targeted by this session.
  VasterModel get model;

  /// Context manager attached to this session.
  ContextManager get contextManager;

  /// Unmodifiable view of message history in this session.
  List<ChatMessage> get history;

  /// Sends a user message turn, compiles context, invokes [targetModel] (or default [model]),
  /// appends model response, and returns response.
  Future<ModelResponse> send(
    ChatMessage userMessage, {
    VasterModel? targetModel,
    GenerationConfig? config,
    CancellationToken? cancelToken,
    List<ContextCacheHint> cacheHints = const [],
  });

  /// Sends a user message turn and streams response chunks from [targetModel] (or default [model]).
  Stream<ModelResponseChunk> sendStream(
    ChatMessage userMessage, {
    VasterModel? targetModel,
    GenerationConfig? config,
    CancellationToken? cancelToken,
    List<ContextCacheHint> cacheHints = const [],
  });

  /// Directly appends [message] to this session's turn history without
  /// triggering model generation.
  ///
  /// Used by agents that build and execute [ModelRequest] themselves (e.g. to
  /// include tool definitions) and need to record user, model, and tool turns
  /// manually. The session remains the sole owner of history; the caller is
  /// responsible for correct turn ordering.
  void appendMessage(ChatMessage message);

  /// Forks current session into a new isolated session thread with deep-copied
  /// turn history. By default the fork shares this session's context manager
  /// (histories share one heap/budget); pass [contextManager] to isolate it.
  ModelSession fork({String? newSessionId, ContextManager? contextManager});

  /// Clears turn history from this session.
  /// Returns the number of turns dropped.
  int clearHistory();
}
