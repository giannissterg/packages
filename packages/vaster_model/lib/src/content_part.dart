import 'dart:typed_data';

/// Represents a single part of content inside a [ChatMessage].
///
/// Implemented as a sealed class hierarchy to enable exhaustive pattern matching.
sealed class ContentPart {
  const ContentPart();

  /// Converts the content part to a JSON-compatible map representation.
  Map<String, dynamic> toJson();

  /// Deserializes a [ContentPart] from a JSON-compatible map.
  factory ContentPart.fromJson(Map<String, dynamic> json) {
    final type = json['type'] as String?;
    return switch (type) {
      'text' => TextPart.fromJson(json),
      'inline_data' => InlineDataPart.fromJson(json),
      'function_call' => FunctionCallPart.fromJson(json),
      'function_response' => FunctionResponsePart.fromJson(json),
      'thought' => ThoughtPart.fromJson(json),
      _ => throw FormatException('Unknown ContentPart type: $type'),
    };
  }
}

/// Text content part.
final class TextPart extends ContentPart {
  final String text;

  const TextPart(this.text);

  factory TextPart.fromJson(Map<String, dynamic> json) {
    return TextPart(json['text'] as String? ?? '');
  }

  @override
  Map<String, dynamic> toJson() => {
        'type': 'text',
        'text': text,
      };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TextPart && runtimeType == other.runtimeType && text == other.text;

  @override
  int get hashCode => text.hashCode;

  @override
  String toString() => 'TextPart("$text")';
}

/// Binary inline data content part (e.g. image, audio, document).
final class InlineDataPart extends ContentPart {
  final String mimeType;
  final Uint8List bytes;

  const InlineDataPart({
    required this.mimeType,
    required this.bytes,
  });

  factory InlineDataPart.fromJson(Map<String, dynamic> json) {
    final rawBytes = json['bytes'];
    final Uint8List bytesList;
    if (rawBytes is List) {
      bytesList = Uint8List.fromList(rawBytes.cast<int>());
    } else {
      bytesList = Uint8List(0);
    }
    return InlineDataPart(
      mimeType: json['mimeType'] as String? ?? 'application/octet-stream',
      bytes: bytesList,
    );
  }

  @override
  Map<String, dynamic> toJson() => {
        'type': 'inline_data',
        'mimeType': mimeType,
        'bytes': bytes.toList(),
      };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is InlineDataPart &&
          runtimeType == other.runtimeType &&
          mimeType == other.mimeType &&
          _bytesEquals(bytes, other.bytes);

  @override
  int get hashCode => Object.hash(mimeType, Object.hashAll(bytes));

  static bool _bytesEquals(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  @override
  String toString() => 'InlineDataPart(mimeType: $mimeType, ${bytes.length} bytes)';
}

/// Function / tool call request emitted by the model.
final class FunctionCallPart extends ContentPart {
  final String callId;
  final String name;
  final Map<String, dynamic> arguments;

  const FunctionCallPart({
    required this.callId,
    required this.name,
    required this.arguments,
  });

  factory FunctionCallPart.fromJson(Map<String, dynamic> json) {
    return FunctionCallPart(
      callId: json['callId'] as String? ?? '',
      name: json['name'] as String? ?? '',
      arguments: Map<String, dynamic>.from(
          json['arguments'] as Map? ?? <String, dynamic>{}),
    );
  }

  @override
  Map<String, dynamic> toJson() => {
        'type': 'function_call',
        'callId': callId,
        'name': name,
        'arguments': arguments,
      };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is FunctionCallPart &&
          runtimeType == other.runtimeType &&
          callId == other.callId &&
          name == other.name;

  @override
  int get hashCode => Object.hash(callId, name);

  @override
  String toString() =>
      'FunctionCallPart(callId: $callId, name: $name, args: $arguments)';
}

/// Function / tool execution response returned to the model.
final class FunctionResponsePart extends ContentPart {
  final String callId;
  final String name;
  final Map<String, dynamic> response;

  const FunctionResponsePart({
    required this.callId,
    required this.name,
    required this.response,
  });

  factory FunctionResponsePart.fromJson(Map<String, dynamic> json) {
    return FunctionResponsePart(
      callId: json['callId'] as String? ?? '',
      name: json['name'] as String? ?? '',
      response: Map<String, dynamic>.from(
          json['response'] as Map? ?? <String, dynamic>{}),
    );
  }

  @override
  Map<String, dynamic> toJson() => {
        'type': 'function_response',
        'callId': callId,
        'name': name,
        'response': response,
      };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is FunctionResponsePart &&
          runtimeType == other.runtimeType &&
          callId == other.callId &&
          name == other.name;

  @override
  int get hashCode => Object.hash(callId, name);

  @override
  String toString() =>
      'FunctionResponsePart(callId: $callId, name: $name, response: $response)';
}

/// Model thought / internal reasoning text part (for chain-of-thought outputs).
final class ThoughtPart extends ContentPart {
  final String thought;

  const ThoughtPart(this.thought);

  factory ThoughtPart.fromJson(Map<String, dynamic> json) {
    return ThoughtPart(json['thought'] as String? ?? '');
  }

  @override
  Map<String, dynamic> toJson() => {
        'type': 'thought',
        'thought': thought,
      };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ThoughtPart &&
          runtimeType == other.runtimeType &&
          thought == other.thought;

  @override
  int get hashCode => thought.hashCode;

  @override
  String toString() => 'ThoughtPart("$thought")';
}
