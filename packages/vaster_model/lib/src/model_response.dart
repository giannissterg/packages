import 'chat_message.dart';
import 'content_part.dart';
import 'usage_metadata.dart';

/// Response payload returned by a model execution request.
class ModelResponse {
  /// The message produced by the model (containing text, function calls, thoughts, etc.).
  final ChatMessage message;

  /// Reason why model execution finished.
  final FinishReason finishReason;

  /// Token usage metadata for prompt and candidates.
  final UsageMetadata usage;

  /// Raw underlying provider payload object, if available.
  final Object? rawResponse;

  const ModelResponse({
    required this.message,
    this.finishReason = FinishReason.stop,
    this.usage = const UsageMetadata(),
    this.rawResponse,
  });

  /// Convenience getter for output text.
  String get text => message.text;

  /// Convenience getter for function calls emitted by model.
  Iterable<FunctionCallPart> get functionCalls => message.functionCalls;

  /// Convenience getter for thoughts emitted by model.
  Iterable<ThoughtPart> get thoughts => message.thoughts;

  Map<String, dynamic> toJson() => {
        'message': message.toJson(),
        'finishReason': finishReason.name,
        'usage': usage.toJson(),
      };

  factory ModelResponse.fromJson(Map<String, dynamic> json) {
    final msgRaw = json['message'] as Map<String, dynamic>? ?? {};
    final finishName = json['finishReason'] as String? ?? 'stop';
    final finishReason = FinishReason.values.firstWhere(
      (f) => f.name == finishName,
      orElse: () => FinishReason.stop,
    );
    final usageRaw = json['usage'] as Map<String, dynamic>?;

    return ModelResponse(
      message: ChatMessage.fromJson(msgRaw),
      finishReason: finishReason,
      usage: usageRaw != null
          ? UsageMetadata.fromJson(usageRaw)
          : const UsageMetadata(),
    );
  }

  @override
  String toString() =>
      'ModelResponse(finish: ${finishReason.name}, text: "$text", calls: ${functionCalls.length})';
}

/// Incremental delta chunk emitted during model streaming.
class ModelResponseChunk {
  /// Content delta produced in this chunk.
  final ContentPart? delta;

  /// Incremental text delta if chunk contains a [TextPart].
  final String? textDelta;

  /// Finish reason if streaming completed in this chunk.
  final FinishReason? finishReason;

  /// Usage metadata if provided at completion.
  final UsageMetadata? usage;

  const ModelResponseChunk({
    this.delta,
    this.textDelta,
    this.finishReason,
    this.usage,
  });

  @override
  String toString() =>
      'ModelResponseChunk(textDelta: "$textDelta", delta: $delta, finish: $finishReason)';
}
