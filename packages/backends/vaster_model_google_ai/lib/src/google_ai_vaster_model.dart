import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:vaster_model/vaster_model.dart';

/// An implementation of [VasterModel] that calls the Google AI Gemini REST API
/// (`generativelanguage.googleapis.com`).
class GoogleAiVasterModel implements VasterModel {
  /// Google AI API key.
  ///
  /// If not supplied, defaults to checking `GEMINI_API_KEY` or `GOOGLE_AI_API_KEY`
  /// environment variables.
  final String apiKey;

  /// Target Gemini model identifier (e.g. `gemini-2.5-flash`, `gemini-1.5-pro`).
  final String targetModel;

  /// Base API endpoint URL.
  final String apiBaseUrl;

  /// Optional HTTP client instance for network requests (useful for mocking).
  final http.Client _client;

  @override
  final String modelName;

  @override
  final ModelCapabilities capabilities;

  GoogleAiVasterModel({
    String? apiKey,
    this.targetModel = 'gemini-2.5-flash',
    this.apiBaseUrl = 'https://generativelanguage.googleapis.com/v1beta',
    http.Client? httpClient,
    // Defaults to the target model id (matching the claude-api convention)
    // so pricing catalogs and telemetry see the real model, not a label.
    String? modelName,
    this.capabilities = const ModelCapabilities(
      maxContextTokens: 1048576,
      maxOutputTokens: 8192,
      supportsStreaming: true,
      supportsFunctionCalling: true,
      supportsVision: true,
      supportsSystemInstruction: true,
      supportsReasoning: true,
    ),
  })  : apiKey = apiKey ??
            Platform.environment['GEMINI_API_KEY'] ??
            Platform.environment['GOOGLE_AI_API_KEY'] ??
            '',
        modelName = modelName ?? targetModel,
        _client = httpClient ?? http.Client();

  @override
  Future<ModelResponse> generate(ModelRequest request) async {
    _ensureApiKey();

    final url = Uri.parse(
      '$apiBaseUrl/models/$targetModel:generateContent?key=$apiKey',
    );
    final payload = _buildRequestBody(request);

    final httpResponse = await _client.post(
      url,
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode(payload),
    );

    if (httpResponse.statusCode != 200) {
      throw StateError(
        'Google AI API error (${httpResponse.statusCode}): ${httpResponse.body}',
      );
    }

    final json = jsonDecode(httpResponse.body) as Map<String, dynamic>;
    return _parseModelResponse(json);
  }

  @override
  Stream<ModelResponseChunk> generateStream(ModelRequest request) async* {
    _ensureApiKey();

    final url = Uri.parse(
      '$apiBaseUrl/models/$targetModel:streamGenerateContent?key=$apiKey&alt=sse',
    );
    final payload = _buildRequestBody(request);

    final httpRequest = http.Request('POST', url)
      ..headers['Content-Type'] = 'application/json'
      ..body = jsonEncode(payload);

    final streamedResponse = await _client.send(httpRequest);

    if (streamedResponse.statusCode != 200) {
      final body = await streamedResponse.stream.bytesToString();
      throw StateError(
        'Google AI streaming error (${streamedResponse.statusCode}): $body',
      );
    }

    final lineStream = streamedResponse.stream
        .transform(utf8.decoder)
        .transform(const LineSplitter());

    await for (final line in lineStream) {
      final trimmed = line.trim();
      if (!trimmed.startsWith('data:')) continue;

      final dataContent = trimmed.substring(5).trim();
      if (dataContent == '[DONE]') break;

      try {
        final json = jsonDecode(dataContent) as Map<String, dynamic>;
        final chunk = _parseResponseChunk(json);
        yield chunk;
      } catch (_) {
        // Skip malformed SSE lines
      }
    }
  }

  void _ensureApiKey() {
    if (apiKey.trim().isEmpty) {
      throw StateError(
        'Google AI API key is missing. Pass `apiKey` or set `GEMINI_API_KEY` '
        'environment variable.',
      );
    }
  }

  Map<String, dynamic> _buildRequestBody(ModelRequest request) {
    final contents = request.messages.map((m) {
      final role = m.role == Role.user ? 'user' : 'model';
      return {
        'role': role,
        'parts': [
          {'text': m.text}
        ],
      };
    }).toList();

    final body = <String, dynamic>{
      'contents': contents,
      'generationConfig': {
        if (request.generationConfig.temperature != null)
          'temperature': request.generationConfig.temperature,
        if (request.generationConfig.topP != null)
          'topP': request.generationConfig.topP,
        if (request.generationConfig.maxOutputTokens != null)
          'maxOutputTokens': request.generationConfig.maxOutputTokens,
        if (request.generationConfig.stopSequences != null &&
            request.generationConfig.stopSequences!.isNotEmpty)
          'stopSequences': request.generationConfig.stopSequences,
      },
    };

    if (request.systemInstruction != null &&
        request.systemInstruction!.text.trim().isNotEmpty) {
      body['systemInstruction'] = {
        'parts': [
          {'text': request.systemInstruction!.text}
        ]
      };
    }

    return body;
  }

  ModelResponse _parseModelResponse(Map<String, dynamic> json) {
    final candidates = json['candidates'] as List? ?? [];
    if (candidates.isEmpty) {
      throw StateError('No response candidates returned by Google AI API');
    }

    final candidate = candidates.first as Map<String, dynamic>;
    final content = candidate['content'] as Map<String, dynamic>? ?? {};
    final parts = content['parts'] as List? ?? [];

    final text = parts
        .whereType<Map<String, dynamic>>()
        .map((p) => p['text'] as String? ?? '')
        .join();

    final finishStr = candidate['finishReason'] as String? ?? 'STOP';
    final finishReason = _parseFinishReason(finishStr);

    final usageRaw = json['usageMetadata'] as Map<String, dynamic>?;
    final usage =
        usageRaw != null ? parseUsageMetadata(usageRaw) : const UsageMetadata();

    return ModelResponse(
      message: ChatMessage.model(text),
      finishReason: finishReason,
      usage: usage,
      rawResponse: json,
    );
  }

  /// Parses a `usageMetadata` payload (shared by response and stream chunks).
  ///
  /// Gemini's `totalTokenCount` already includes thought tokens — pass it
  /// through verbatim rather than recomputing.
  static UsageMetadata parseUsageMetadata(Map<String, dynamic> usageRaw) =>
      UsageMetadata(
        promptTokenCount: usageRaw['promptTokenCount'] as int? ?? 0,
        candidatesTokenCount: usageRaw['candidatesTokenCount'] as int? ?? 0,
        thoughtsTokenCount: usageRaw['thoughtsTokenCount'] as int? ?? 0,
        cacheReadTokenCount: usageRaw['cachedContentTokenCount'] as int? ?? 0,
        totalTokenCount: usageRaw['totalTokenCount'] as int?,
        source: UsageSource.measured,
      );

  ModelResponseChunk _parseResponseChunk(Map<String, dynamic> json) {
    final candidates = json['candidates'] as List? ?? [];
    String? textDelta;
    FinishReason? finishReason;

    if (candidates.isNotEmpty) {
      final candidate = candidates.first as Map<String, dynamic>;
      final content = candidate['content'] as Map<String, dynamic>? ?? {};
      final parts = content['parts'] as List? ?? [];

      textDelta = parts
          .whereType<Map<String, dynamic>>()
          .map((p) => p['text'] as String? ?? '')
          .join();

      if (candidate.containsKey('finishReason')) {
        final reasonStr = candidate['finishReason'] as String? ?? '';
        if (reasonStr.isNotEmpty) {
          finishReason = _parseFinishReason(reasonStr);
        }
      }
    }

    final usageRaw = json['usageMetadata'] as Map<String, dynamic>?;
    // Gemini repeats cumulative usage on each chunk — consumers take-last.
    final usage = usageRaw != null ? parseUsageMetadata(usageRaw) : null;

    return ModelResponseChunk(
      delta: textDelta != null ? TextPart(textDelta) : null,
      textDelta: textDelta,
      finishReason: finishReason,
      usage: usage,
    );
  }

  FinishReason _parseFinishReason(String reason) {
    switch (reason.toUpperCase()) {
      case 'STOP':
        return FinishReason.stop;
      case 'MAX_TOKENS':
        return FinishReason.maxTokens;
      case 'SAFETY':
        return FinishReason.safety;
      default:
        return FinishReason.unknown;
    }
  }
}
