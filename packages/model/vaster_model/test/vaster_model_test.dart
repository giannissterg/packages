import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:vaster_model/vaster_model.dart';

void main() {
  group('Role & ContentPart', () {
    test('Role enum values', () {
      expect(Role.values, containsAll([Role.system, Role.user, Role.model, Role.tool]));
    });

    test('TextPart serialization and pattern matching', () {
      const ContentPart part = TextPart('Hello Vaster');
      expect(part.toJson(), equals({'type': 'text', 'text': 'Hello Vaster'}));

      final deserialized = ContentPart.fromJson(part.toJson());
      expect(deserialized, isA<TextPart>());
      expect((deserialized as TextPart).text, equals('Hello Vaster'));

      final label = switch (part) {
        TextPart(text: final t) => 'text: $t',
        InlineDataPart() => 'inline_data',
        FunctionCallPart() => 'function_call',
        FunctionResponsePart() => 'function_response',
        ThoughtPart() => 'thought',
      };
      expect(label, equals('text: Hello Vaster'));
    });

    test('FunctionCallPart & FunctionResponsePart matching', () {
      const callPart = FunctionCallPart(
        callId: 'call_1',
        name: 'read_file',
        arguments: {'path': 'ideas.md'},
      );

      expect(callPart.callId, equals('call_1'));
      expect(callPart.name, equals('read_file'));
      expect(callPart.arguments['path'], equals('ideas.md'));

      final json = callPart.toJson();
      final restored = ContentPart.fromJson(json);
      expect(restored, isA<FunctionCallPart>());
      expect((restored as FunctionCallPart).name, equals('read_file'));

      const responsePart = FunctionResponsePart(
        callId: 'call_1',
        name: 'read_file',
        response: {'content': 'ideas content...'},
      );

      expect(responsePart.toJson()['type'], equals('function_response'));
    });

    test('InlineDataPart serialization', () {
      final bytes = Uint8List.fromList([1, 2, 3, 4]);
      final dataPart = InlineDataPart(mimeType: 'image/png', bytes: bytes);
      final json = dataPart.toJson();
      final restored = ContentPart.fromJson(json) as InlineDataPart;

      expect(restored.mimeType, equals('image/png'));
      expect(restored.bytes, equals(bytes));
    });
  });

  group('ChatMessage & ModelRequest & ModelResponse', () {
    test('ChatMessage constructors and getters', () {
      final userMsg = ChatMessage.user('What is Vaster?');
      expect(userMsg.role, equals(Role.user));
      expect(userMsg.text, equals('What is Vaster?'));

      final modelMsg = ChatMessage(
        role: Role.model,
        parts: [
          const ThoughtPart('Analyzing architecture'),
          const FunctionCallPart(
            callId: 'c1',
            name: 'get_context',
            arguments: {},
          ),
        ],
      );

      expect(modelMsg.thoughts.first.thought, equals('Analyzing architecture'));
      expect(modelMsg.functionCalls.first.name, equals('get_context'));
    });

    test('ModelRequest json roundtrip', () {
      final req = ModelRequest(
        systemInstruction: ChatMessage.system('You are an execution VM assistant.'),
        messages: [ChatMessage.user('Hello')],
        tools: [
          const ToolDefinition(
            name: 'run_code',
            description: 'Executes dart code',
          )
        ],
        generationConfig: const GenerationConfig(temperature: 0.7),
      );

      final json = req.toJson();
      final restored = ModelRequest.fromJson(json);

      expect(restored.systemInstruction?.text, equals('You are an execution VM assistant.'));
      expect(restored.messages.first.text, equals('Hello'));
      expect(restored.tools.first.name, equals('run_code'));
      expect(restored.generationConfig.temperature, equals(0.7));
    });

    test('ModelResponse json roundtrip', () {
      final res = ModelResponse(
        message: ChatMessage.model('Response text'),
        finishReason: FinishReason.stop,
        usage: const UsageMetadata(promptTokenCount: 10, candidatesTokenCount: 5),
      );

      final json = res.toJson();
      final restored = ModelResponse.fromJson(json);

      expect(restored.text, equals('Response text'));
      expect(restored.finishReason, equals(FinishReason.stop));
      expect(restored.usage.totalTokenCount, equals(15));
    });
  });
}
