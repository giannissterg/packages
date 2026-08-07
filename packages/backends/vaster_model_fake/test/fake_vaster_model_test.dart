import 'package:test/test.dart';
import 'package:vaster_model/vaster_model.dart';
import 'package:vaster_model_fake/vaster_model_fake.dart';

void main() {
  group('FakeVasterModel Backend', () {
    test('generate returns structured model response', () async {
      final model = FakeVasterModel(defaultResponseText: 'Hello from FakeModel');
      final request = ModelRequest(messages: [ChatMessage.user('Hi')]);

      final response = await model.generate(request);

      expect(response.finishReason, equals(FinishReason.stop));
      expect(response.text, contains('Hello from FakeModel'));
      expect(model.recordedRequests, hasLength(1));
    });

    test('generateStream streams response chunks', () async {
      final model = FakeVasterModel(defaultResponseText: 'One two three');
      final request = ModelRequest(messages: [ChatMessage.user('Count')]);

      final chunks = await model.generateStream(request).toList();

      expect(chunks.isNotEmpty, isTrue);
      final textDeltas = chunks.map((c) => c.textDelta).whereType<String>().join();
      expect(textDeltas, contains('One two three'));
    });

    test('custom handler generates function call response', () async {
      final model = FakeVasterModel(
        handler: (req) async {
          return ModelResponse(
            message: ChatMessage(
              role: Role.model,
              parts: [
                const FunctionCallPart(callId: 'call_99', name: 'list_files', arguments: {'dir': '/'}),
              ],
            ),
            finishReason: FinishReason.toolCalls,
          );
        },
      );

      final response = await model.generate(ModelRequest(messages: []));
      expect(response.finishReason, equals(FinishReason.toolCalls));
      expect(response.functionCalls.first.name, equals('list_files'));
    });
  });
}
