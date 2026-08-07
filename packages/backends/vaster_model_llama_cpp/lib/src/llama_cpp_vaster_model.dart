import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:vaster_model/vaster_model.dart';

import 'llama_cpp_kv_cache_controller.dart';

/// A [VasterModel] backend over the llama.cpp server's native `/completion`
/// API — Vaster's **state-addressed** physical backend.
///
/// When constructed with a [kvController], incoming [ModelRequest.cacheHints]
/// are lowered to *real* physical context: the first hint whose fingerprint
/// maps to materialized KV state is restored into the slot before generation
/// (`cache_prompt: true` then reuses the loaded prefix), so pinned Vaster
/// context regions skip prompt re-processing entirely.
class LlamaCppVasterModel implements VasterModel {
  final String baseUrl;
  final int slotId;

  /// Optional physical-context controller: enables KV restore from cache hints.
  final LlamaCppKvCacheController? kvController;

  final http.Client Function() _clientFactory;

  @override
  final String modelName;

  @override
  final ModelCapabilities capabilities;

  LlamaCppVasterModel({
    this.baseUrl = 'http://127.0.0.1:8080',
    this.slotId = 0,
    this.kvController,
    http.Client Function()? clientFactory,
    this.modelName = 'llama-cpp',
    this.capabilities = const ModelCapabilities(
      maxContextTokens: 32768,
      maxOutputTokens: 8192,
      supportsStreaming: true,
      supportsFunctionCalling: false,
      supportsVision: false,
      supportsSystemInstruction: true,
      supportsReasoning: false,
    ),
  }) : _clientFactory = clientFactory ?? http.Client.new;

  @override
  Future<ModelResponse> generate(ModelRequest request) async {
    await _restoreFromHints(request.cacheHints);

    final client = _clientFactory();
    try {
      final response = await client.post(
        Uri.parse('$baseUrl/completion'),
        headers: {'content-type': 'application/json'},
        body: jsonEncode(buildRequestBody(request, slotId: slotId)),
      );
      if (response.statusCode != 200) {
        throw StateError('llama.cpp completion failed ${response.statusCode}: ${response.body}');
      }
      return parseResponse(jsonDecode(response.body) as Map<String, dynamic>);
    } finally {
      client.close();
    }
  }

  @override
  Stream<ModelResponseChunk> generateStream(ModelRequest request) async* {
    await _restoreFromHints(request.cacheHints);

    final client = _clientFactory();
    try {
      final httpRequest = http.Request('POST', Uri.parse('$baseUrl/completion'))
        ..headers['content-type'] = 'application/json'
        ..body = jsonEncode(buildRequestBody(request, slotId: slotId, stream: true));
      final streamed = await client.send(httpRequest);
      if (streamed.statusCode != 200) {
        final body = await streamed.stream.bytesToString();
        throw StateError('llama.cpp stream failed ${streamed.statusCode}: $body');
      }

      await for (final line in streamed.stream.transform(utf8.decoder).transform(const LineSplitter())) {
        if (!line.startsWith('data:')) continue;
        final payload = line.substring(5).trim();
        if (payload.isEmpty) continue;
        final event = jsonDecode(payload) as Map<String, dynamic>;
        final content = event['content'] as String? ?? '';
        if (content.isNotEmpty) {
          yield ModelResponseChunk(delta: TextPart(content), textDelta: content);
        }
        if (event['stop'] == true) {
          yield ModelResponseChunk(finishReason: _mapStop(event), usage: _parseUsage(event));
        }
      }
    } finally {
      client.close();
    }
  }

  Future<void> _restoreFromHints(List<ContextCacheHint> hints) async {
    final controller = kvController;
    if (controller == null) return;
    for (final hint in hints) {
      final handle = await controller.lookup(hint.contentFingerprint);
      if (handle != null) {
        await controller.restore(handle);
        return; // slot state restored — cache_prompt reuses the prefix
      }
    }
  }

  /// Lowers a [ModelRequest] into a llama.cpp `/completion` body (pure).
  static Map<String, dynamic> buildRequestBody(
    ModelRequest request, {
    required int slotId,
    bool stream = false,
  }) {
    final config = request.generationConfig;
    return {
      'prompt': composePrompt(request),
      'n_predict': config.maxOutputTokens ?? 1024,
      'id_slot': slotId,
      'cache_prompt': true, // always reuse the longest matching KV prefix
      if (stream) 'stream': true,
      if (config.temperature != null) 'temperature': config.temperature,
      if (config.topP != null) 'top_p': config.topP,
      if (config.topK != null) 'top_k': config.topK,
      if (config.stopSequences != null && config.stopSequences!.isNotEmpty) 'stop': config.stopSequences,
      // Structured outputs lower to llama.cpp's native json_schema constraint.
      if (config.responseSchema != null) 'json_schema': config.responseSchema,
    };
  }

  /// Flattens the typed conversation into a plain prompt. IMPORTANT for KV
  /// reuse: stable content (system instruction, earlier turns) renders first
  /// so materialized prefixes stay byte-identical across calls.
  static String composePrompt(ModelRequest request) {
    final buffer = StringBuffer();
    final system = request.systemInstruction?.text.trim();
    if (system != null && system.isNotEmpty) {
      buffer.writeln(system);
      buffer.writeln();
    }
    for (final message in request.messages) {
      final text = message.text.trim();
      if (text.isEmpty) continue;
      buffer.writeln('${message.role.name}: $text');
    }
    buffer.write('model:');
    return buffer.toString();
  }

  /// Parses a llama.cpp `/completion` response (pure).
  static ModelResponse parseResponse(Map<String, dynamic> json) {
    return ModelResponse(
      message: ChatMessage.model(json['content'] as String? ?? ''),
      finishReason: _mapStop(json),
      usage: _parseUsage(json),
      rawResponse: json,
    );
  }

  static FinishReason _mapStop(Map<String, dynamic> json) {
    if (json['stopped_limit'] == true) return FinishReason.maxTokens;
    return FinishReason.stop;
  }

  static UsageMetadata _parseUsage(Map<String, dynamic> json) {
    // tokens_evaluated counts freshly-processed prompt tokens only; the
    // cached prefix reused via cache_prompt arrives in tokens_cached. Total
    // prompt = evaluated + cached.
    final evaluated = (json['tokens_evaluated'] as int?) ?? 0;
    final cached = (json['tokens_cached'] as int?) ?? 0;
    return UsageMetadata(
      promptTokenCount: evaluated + cached,
      candidatesTokenCount: (json['tokens_predicted'] as int?) ?? 0,
      cacheReadTokenCount: cached,
      source: UsageSource.measured,
    );
  }
}
