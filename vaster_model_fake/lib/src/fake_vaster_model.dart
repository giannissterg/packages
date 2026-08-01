import 'dart:async';

import 'package:vaster_model/vaster_model.dart';

/// A mock/fake implementation of [VasterModel] for offline testing, local VM development,
/// and automated test scenarios.
class FakeVasterModel implements VasterModel {
  @override
  final String modelName;

  @override
  final ModelCapabilities capabilities;

  /// Custom handler function to dynamically inspect requests and generate responses.
  final FutureOr<ModelResponse> Function(ModelRequest request)? handler;

  /// Default static response text returned when no handler is provided.
  final String defaultResponseText;

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
    this.handler,
  });

  @override
  Future<ModelResponse> generate(ModelRequest request) async {
    recordedRequests.add(request);

    if (handler != null) {
      return await handler!(request);
    }

    final userText = request.messages.isNotEmpty ? request.messages.last.text : '';
    final responseText = '$defaultResponseText (Echo: "$userText")';

    final promptTokens = request.messages.fold<int>(
      0,
      (sum, msg) => sum + msg.text.length,
    );

    return ModelResponse(
      message: ChatMessage.model(responseText),
      finishReason: FinishReason.stop,
      usage: UsageMetadata(
        promptTokenCount: promptTokens,
        candidatesTokenCount: responseText.length,
      ),
    );
  }

  @override
  Stream<ModelResponseChunk> generateStream(ModelRequest request) async* {
    recordedRequests.add(request);

    final fullResponse = await (handler != null
        ? handler!(request)
        : Future.value(ModelResponse(
            message: ChatMessage.model('$defaultResponseText (Stream)'),
            finishReason: FinishReason.stop,
          )));

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
