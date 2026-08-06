import 'model_capabilities.dart';
import 'model_request.dart';
import 'model_response.dart';

/// Standard interface for interacting with an LLM model backend in the Vaster runtime.
abstract interface class VasterModel {
  /// Name or model identifier (e.g. 'gemini-1.5-pro', 'gpt-4o', 'fake-model').
  String get modelName;

  /// Operational capabilities and token resource limits of this model backend.
  ModelCapabilities get capabilities;

  /// Executes a single generation request synchronously and returns [ModelResponse].
  Future<ModelResponse> generate(ModelRequest request);

  /// Executes a generation request and yields a stream of [ModelResponseChunk] deltas.
  Stream<ModelResponseChunk> generateStream(ModelRequest request);
}
