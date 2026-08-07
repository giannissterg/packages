import 'handler_vaster_model.dart';
import 'model_capabilities.dart';
import 'model_request.dart';
import 'model_response.dart';

/// Standard interface for interacting with an LLM model backend in the Vaster runtime.
abstract interface class VasterModel {
  /// Bring-your-own-model, the first-class integration: wraps the caller's
  /// OWN model invocation — any SDK, proxy, or local server — as a
  /// [VasterModel]. The handler sees the COMPLETE request (messages, system
  /// instruction, tools, `responseSchema`, `cancelToken`) and owns the
  /// [ModelResponse], including real usage when it has it; exceptions
  /// propagate untouched, so resilience and cancellation compose exactly as
  /// for shipped backends. Streaming defaults to the one-terminal-chunk
  /// synthesis of non-streaming backends; pass [onGenerateStream] to stream
  /// for real.
  factory VasterModel.fromHandler(
    Future<ModelResponse> Function(ModelRequest request) onGenerate, {
    String modelName,
    ModelCapabilities capabilities,
    Stream<ModelResponseChunk> Function(ModelRequest request)? onGenerateStream,
  }) = HandlerVasterModel;

  /// The simple tier of [VasterModel.fromHandler]: the same full request
  /// in — nothing silently dropped — plain text out. The response carries
  /// default usage; the machine's metering estimates and charges it
  /// (estimated work is not free work).
  factory VasterModel.fromTextHandler(
    Future<String> Function(ModelRequest request) onText, {
    String modelName,
    ModelCapabilities capabilities,
  }) = HandlerVasterModel.text;

  /// Name or model identifier (e.g. 'gemini-1.5-pro', 'gpt-4o', 'fake-model').
  String get modelName;

  /// Operational capabilities and token resource limits of this model backend.
  ModelCapabilities get capabilities;

  /// Executes a single generation request synchronously and returns [ModelResponse].
  Future<ModelResponse> generate(ModelRequest request);

  /// Executes a generation request and yields a stream of [ModelResponseChunk] deltas.
  Stream<ModelResponseChunk> generateStream(ModelRequest request);
}
