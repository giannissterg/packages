import 'package:test/test.dart';
import 'package:vaster_model/vaster_model.dart';
import 'package:vaster_model_llama_cpp/vaster_model_llama_cpp.dart';

void main() {
  group('LlamaCppVasterModel request lowering', () {
    test('builds /completion body with slot + cache_prompt', () {
      final request = ModelRequest(
        systemInstruction: ChatMessage.system('Be terse.'),
        messages: [ChatMessage.user('hello')],
        generationConfig: const GenerationConfig(maxOutputTokens: 256),
      );

      final body = LlamaCppVasterModel.buildRequestBody(request, slotId: 3);
      expect(body['id_slot'], equals(3));
      expect(body['cache_prompt'], isTrue);
      expect(body['n_predict'], equals(256));
      final prompt = body['prompt'] as String;
      expect(prompt, startsWith('Be terse.'));
      expect(prompt, contains('user: hello'));
      expect(prompt, endsWith('model:'));
    });

    test('responseSchema lowers to native json_schema constraint', () {
      final request = ModelRequest(
        messages: [ChatMessage.user('extract')],
        generationConfig: const GenerationConfig(responseSchema: {
          'type': 'object',
          'properties': {
            'name': {'type': 'string'},
          },
        }),
      );
      final body = LlamaCppVasterModel.buildRequestBody(request, slotId: 0);
      expect(body['json_schema'], isNotNull);
    });

    test('stable prefix ordering: system + history render before live turn', () {
      final request = ModelRequest(
        systemInstruction: ChatMessage.system('SYS'),
        messages: [
          ChatMessage.user('turn 1'),
          ChatMessage.model('answer 1'),
          ChatMessage.user('turn 2'),
        ],
      );
      final prompt =
          LlamaCppVasterModel.buildRequestBody(request, slotId: 0)['prompt']
              as String;
      expect(prompt.indexOf('SYS'), lessThan(prompt.indexOf('turn 1')));
      expect(prompt.indexOf('turn 1'), lessThan(prompt.indexOf('answer 1')));
      expect(prompt.indexOf('answer 1'), lessThan(prompt.indexOf('turn 2')));
    });
  });

  group('LlamaCppVasterModel response parsing', () {
    test('parses content, stop reason, and exact usage', () {
      final response = LlamaCppVasterModel.parseResponse({
        'content': ' The answer is 42.',
        'stop': true,
        'stopped_limit': false,
        'tokens_evaluated': 128,
        'tokens_predicted': 7,
      });
      expect(response.text, contains('42'));
      expect(response.finishReason, equals(FinishReason.stop));
      expect(response.usage.promptTokenCount, equals(128));
      expect(response.usage.candidatesTokenCount, equals(7));
    });

    test('stopped_limit maps to maxTokens', () {
      final response = LlamaCppVasterModel.parseResponse({
        'content': 'truncated…',
        'stopped_limit': true,
      });
      expect(response.finishReason, equals(FinishReason.maxTokens));
    });
  });

  group('LlamaCppKvCacheController', () {
    test('declares state-addressed, persistent capabilities', () {
      final controller = LlamaCppKvCacheController();
      expect(controller.capabilities.isStateAddressed, isTrue);
      expect(controller.capabilities.supportsPersistence, isTrue);
      expect(controller.backendId, equals('llama_cpp'));
    });
  });
}
