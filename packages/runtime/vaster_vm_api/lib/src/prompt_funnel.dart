import 'package:vaster_model/vaster_model.dart';

/// The VM's prompt funnel — the four model-turn verbs, and nothing else.
///
/// This is the capability facet a model-conversation collaborator holds
/// (the runtime's `DecisionArbiter` and `ToolCallOrchestrator`): a
/// component that converses with the model should be TYPED as one, not as
/// something that can also mount filesystems, create agents, or shut the
/// VM down. [VasterVirtualMachine] implements this facet; nothing changes
/// at runtime — only what a dependent's constructor signature claims.
///
/// Every verb carries the funnel's compiled-context contract: the VM's
/// global context regions travel ahead of the turn (pinned/admitted
/// regions as leading messages, system-class regions as the system
/// instruction), and each call is a turn boundary — ephemeral-lifetime
/// regions are pruned after it. Implementations MUST preserve this; a
/// sessionless prompt that drops pinned context regressed silently once
/// (caught by KV token-exact prefix validation) and must never do so
/// again.
abstract interface class PromptFunnel {
  /// Direct (sessionless) model prompt turn.
  Future<ModelResponse> prompt(
    String promptText, {
    VasterModel? model,
    GenerationConfig? config,
    CancellationToken? cancelToken,
    List<ContextCacheHint>? cacheHints,
  });

  /// Session-aware prompt turn routing through [sessionId]'s turn history
  /// and layered context.
  Future<ModelResponse> promptInSession(
    String sessionId,
    String promptText, {
    VasterModel? model,
    GenerationConfig? config,
    CancellationToken? cancelToken,
    List<ContextCacheHint>? cacheHints,
  });

  /// Typed continuation turn: a full message transcript (including
  /// `tool_use` / `tool_result` parts) plus tool definitions. This is the
  /// ABI-preserving path used by the runtime's tool-calling loop.
  Future<ModelResponse> promptWithHistory(
    List<ChatMessage> messages, {
    VasterModel? model,
    List<ToolDefinition>? tools,
    GenerationConfig? config,
    CancellationToken? cancelToken,
    List<ContextCacheHint>? cacheHints,
  });

  /// Direct model prompt streaming — the same sessionless contract as
  /// [prompt].
  Stream<ModelResponseChunk> promptStream(
    String promptText, {
    VasterModel? model,
    GenerationConfig? config,
    CancellationToken? cancelToken,
    List<ContextCacheHint>? cacheHints,
  });
}
