import 'dart:async';

import 'package:vaster_model/vaster_model.dart';
import 'package:vaster_token_estimate/vaster_token_estimate.dart';

/// A mock/fake implementation of [VasterModel] for offline testing, local VM development,
/// and automated test scenarios.
class FakeVasterModel implements VasterModel {
  @override
  final String modelName;

  @override
  final ModelCapabilities capabilities;

  /// Custom handler function to dynamically inspect requests and generate responses.
  final FutureOr<ModelResponse> Function(ModelRequest request)? handler;

  /// Map of prompt substrings to specific response text outputs.
  final Map<String, String> responseMap;

  /// Default static response text returned when no handler or response map match is found.
  final String defaultResponseText;

  /// Builds the [UsageMetadata] reported for a generated response, letting
  /// tests pin exact token/cost numbers. When null, usage defaults to a
  /// token-scale length estimate (~4 chars/token, `source: estimated`).
  final UsageMetadata Function(ModelRequest request, String responseText)?
      usageBuilder;

  /// Recorded history of requests received by this model backend.
  final List<ModelRequest> recordedRequests = [];

  FakeVasterModel({
    this.modelName = 'fake-vaster-model',
    this.capabilities = const ModelCapabilities(
      maxContextTokens: 128000,
      maxOutputTokens: 4096,
      supportsStreaming: true,
      supportsFunctionCalling: true,
      supportsVision: true,
      supportsSystemInstruction: true,
      supportsReasoning: true,
    ),
    this.defaultResponseText = 'Fake model response text',
    this.responseMap = const {},
    this.handler,
    this.usageBuilder,
  });

  @override
  Future<ModelResponse> generate(ModelRequest request) async {
    recordedRequests.add(request);

    if (handler != null) {
      return await handler!(request);
    }

    final userText = request.messages.isNotEmpty ? request.messages.last.text : '';
    final lowerUserText = userText.toLowerCase();

    String? matchedText;
    for (final entry in responseMap.entries) {
      if (lowerUserText.contains(entry.key.toLowerCase())) {
        matchedText = entry.value;
        break;
      }
    }

    final responseText = matchedText ?? '$defaultResponseText (Echo: "$userText")';

    // Token-scale estimate (~4 chars/token), mirroring real backends'
    // magnitudes; raw character counts would be ~4x inflated.
    final promptTokens = request.messages.fold<int>(
      0,
      (sum, msg) => sum + TokenEstimate.forText(msg.text),
    );

    return ModelResponse(
      message: ChatMessage.model(responseText),
      finishReason: FinishReason.stop,
      usage: usageBuilder?.call(request, responseText) ??
          UsageMetadata(
            promptTokenCount: promptTokens,
            candidatesTokenCount: TokenEstimate.forText(responseText),
          ),
    );
  }

  @override
  Stream<ModelResponseChunk> generateStream(ModelRequest request) async* {
    recordedRequests.add(request);

    final fullResponse = await generate(request);

    for (final part in fullResponse.message.parts) {
      if (part is TextPart) {
        final words = part.text.split(' ');
        for (var i = 0; i < words.length; i++) {
          final isLast = i == words.length - 1;
          final wordWithSpace = isLast ? words[i] : '${words[i]} ';
          yield ModelResponseChunk(
            delta: TextPart(wordWithSpace),
            textDelta: wordWithSpace,
          );
          await Future.delayed(const Duration(milliseconds: 5));
        }
      } else {
        yield ModelResponseChunk(delta: part);
      }
    }

    yield ModelResponseChunk(
      finishReason: fullResponse.finishReason,
      usage: fullResponse.usage,
    );
  }
}
