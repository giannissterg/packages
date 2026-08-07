import 'chat_message.dart';
import 'model_capabilities.dart';
import 'model_request.dart';
import 'model_response.dart';
import 'usage_metadata.dart';
import 'vaster_model_interface.dart';

/// A [VasterModel] over the caller's OWN model invocation — any SDK, proxy,
/// or local server. Bring-your-own-model is the framework's first-class
/// integration: the machine provides everything the call does not —
/// durability, recording/replay, budgets, metering, and resilience
/// composition (`ResilientVasterModel`, `RecordingVasterModel` wrap this
/// like any backend).
///
/// The handler sees the COMPLETE [ModelRequest] — messages, system
/// instruction, tools, `responseSchema`, `cancelToken` — and its exceptions
/// propagate untouched, so retry/fallback and cancellation semantics are
/// exactly those of a shipped backend.
///
/// Construct via [VasterModel.fromHandler] (full tier: the handler owns the
/// [ModelResponse], including REAL usage when it has it) or
/// [VasterModel.fromTextHandler] (simple tier: text out; the machine's
/// estimation path meters the call — estimated work is charged work).
final class HandlerVasterModel implements VasterModel {
  /// The honest "we don't know your model" default, overridable per call
  /// site: a modern mid-size window with functions and streaming on.
  static const ModelCapabilities defaultCapabilities = ModelCapabilities(
    maxContextTokens: 128000,
    maxOutputTokens: 4096,
    supportsStreaming: true,
    supportsFunctionCalling: true,
    supportsVision: false,
    supportsSystemInstruction: true,
    supportsReasoning: false,
  );

  @override
  final String modelName;

  @override
  final ModelCapabilities capabilities;

  final Future<ModelResponse> Function(ModelRequest request) _onGenerate;
  final Stream<ModelResponseChunk> Function(ModelRequest request)? _onGenerateStream;

  /// Full tier — see [VasterModel.fromHandler].
  HandlerVasterModel(
    Future<ModelResponse> Function(ModelRequest request) onGenerate, {
    this.modelName = 'handler-model',
    this.capabilities = defaultCapabilities,
    this._onGenerateStream,
  }) : _onGenerate = onGenerate;

  /// Text tier — see [VasterModel.fromTextHandler]: the same full request
  /// in, plain text out, wrapped with default (machine-estimated) usage.
  HandlerVasterModel.text(
    Future<String> Function(ModelRequest request) onText, {
    this.modelName = 'handler-model',
    this.capabilities = defaultCapabilities,
  }) : _onGenerateStream = null,
       _onGenerate = ((request) async =>
           ModelResponse(message: ChatMessage.model(await onText(request)), finishReason: FinishReason.stop));

  @override
  Future<ModelResponse> generate(ModelRequest request) => _onGenerate(request);

  /// Without a stream handler, synthesizes the non-streaming backends'
  /// contract: ONE terminal chunk carrying the full text, the finish
  /// reason, and the cumulative usage (the final chunk is authoritative —
  /// see [ModelResponseChunk.usage]).
  @override
  Stream<ModelResponseChunk> generateStream(ModelRequest request) {
    final custom = _onGenerateStream;
    if (custom != null) return custom(request);
    return () async* {
      final response = await _onGenerate(request);
      yield ModelResponseChunk(
        textDelta: response.message.text,
        finishReason: response.finishReason,
        usage: response.usage,
      );
    }();
  }
}
