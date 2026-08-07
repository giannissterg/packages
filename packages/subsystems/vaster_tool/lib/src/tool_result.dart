import 'package:vaster_model/vaster_model.dart';

/// Execution output payload produced by invoking an [ExecutableTool].
class ToolResult {
  /// Matching function call identifier emitted by model backend.
  final String callId;

  /// Name of the invoked tool.
  final String name;

  /// Output response payload (JSON-compatible map).
  final Map<String, dynamic> response;

  /// Whether tool execution resulted in an error.
  final bool isError;

  /// Error details if [isError] is true.
  final String? errorDetails;

  /// Duration spent executing tool.
  final Duration executionDuration;

  const ToolResult({
    required this.callId,
    required this.name,
    required this.response,
    this.isError = false,
    this.errorDetails,
    this.executionDuration = Duration.zero,
  });

  /// Converts this result into a [ChatMessage] tool response turn.
  ChatMessage toChatMessage() {
    return ChatMessage.toolResponse(callId, name, response);
  }

  /// Converts this result into a [FunctionResponsePart].
  FunctionResponsePart toResponsePart() {
    return FunctionResponsePart(callId: callId, name: name, response: response);
  }

  Map<String, dynamic> toJson() => {
    'callId': callId,
    'name': name,
    'response': response,
    'isError': isError,
    if (errorDetails != null) 'errorDetails': errorDetails,
    'executionDurationMs': executionDuration.inMilliseconds,
  };

  @override
  String toString() => 'ToolResult(callId: "$callId", name: "$name", isError: $isError, response: $response)';
}
