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

  /// Optional context manager attached to this session.
  ContextManager? get contextManager;

  /// Unmodifiable view of message history in this session.
  List<ChatMessage> get history;

  /// Sends a user message turn, compiles context, invokes [targetModel] (or default [model]),
  /// appends model response, and returns response.
  Future<ModelResponse> send(
    ChatMessage userMessage, {
    VasterModel? targetModel,
    GenerationConfig? config,
    CancellationToken? cancelToken,
  });

  /// Sends a user message turn and streams response chunks from [targetModel] (or default [model]).
  Stream<ModelResponseChunk> sendStream(
    ChatMessage userMessage, {
    VasterModel? targetModel,
    GenerationConfig? config,
    CancellationToken? cancelToken,
  });

  /// Forks current session into a new isolated session thread with deep-copied turn history.
  ModelSession fork({String? newSessionId});

  /// Clears turn history from this session.
  void clearHistory();
}
