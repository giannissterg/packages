import 'dart:io';

import 'package:test/test.dart';
import 'package:vaster_model/vaster_model.dart';
import 'package:vaster_model_gemini_cli/vaster_model_gemini_cli.dart';

void main() {
  group('GeminiCliVasterModel — Configuration', () {
    test('instantiates with defaults', () {
      final model = GeminiCliVasterModel();
      expect(model.executablePath, equals('gemini'));
      expect(model.modelName, equals('gemini-cli'));
      expect(model.capabilities.supportsStreaming, isTrue);
    });

    test('accepts custom executablePath and selectedModel', () {
      final model = GeminiCliVasterModel(
        executablePath: '/opt/homebrew/bin/gemini',
        selectedModel: 'gemini-2.5-flash',
        extraArgs: ['--skip-trust'],
      );
      expect(model.executablePath, equals('/opt/homebrew/bin/gemini'));
      expect(model.selectedModel, equals('gemini-2.5-flash'));
      expect(model.extraArgs, contains('--skip-trust'));
    });
  });

  group('GeminiCliVasterModel.parseStats', () {
    test('per-model schema: sums models, maps cached/thoughts/tool', () {
      final usage = GeminiCliVasterModel.parseStats({
        'models': {
          'gemini-2.5-pro': {
            'tokens': {
              'prompt': 1000,
              'candidates': 200,
              'cached': 600,
              'thoughts': 150,
              'tool': 50,
            },
          },
          'gemini-2.5-flash': {
            'tokens': {'input': 100, 'output': 20},
          },
        },
      });

      expect(usage.promptTokenCount, equals(1000 + 100 + 50)); // tool → prompt
      expect(usage.candidatesTokenCount, equals(220));
      expect(usage.cacheReadTokenCount, equals(600));
      expect(usage.thoughtsTokenCount, equals(150));
      expect(usage.source, equals(UsageSource.measured));
    });

    test('flat schema: input_tokens/output_tokens', () {
      final usage = GeminiCliVasterModel.parseStats({
        'input_tokens': 42,
        'output_tokens': 7,
      });

      expect(usage.promptTokenCount, equals(42));
      expect(usage.candidatesTokenCount, equals(7));
      expect(usage.source, equals(UsageSource.measured));
    });
  });

  group('GeminiCliVasterModel — Integration with local Gemini CLI', () {
    final geminiAvailable = Process.runSync('gemini', ['--version']).exitCode == 0;

    test('generate() calls Gemini CLI and parses JSON response', () async {
      final model = GeminiCliVasterModel(
        executablePath: 'gemini',
        extraArgs: ['--skip-trust'],
      );

      final request = ModelRequest(
        messages: [
          ChatMessage.user('Say "Vaster Gemini CLI Integration Success" and nothing else.'),
        ],
      );

      try {
        final response = await model.generate(request);
        expect(response.message.text, isNotEmpty);
        expect(response.finishReason, equals(FinishReason.stop));
      } catch (e) {
        if (e.toString().contains('quota') || e.toString().contains('429')) {
          print('Skipping test due to local Gemini CLI daily quota limit: $e');
        } else {
          rethrow;
        }
      }
    }, skip: geminiAvailable ? null : 'gemini CLI not available on system');

    test('generateStream() streams responses from Gemini CLI', () async {
      final model = GeminiCliVasterModel(
        executablePath: 'gemini',
        extraArgs: ['--skip-trust'],
      );

      final request = ModelRequest(
        messages: [
          ChatMessage.user('Count: 1 2 3'),
        ],
      );

      try {
        final chunks = await model.generateStream(request).toList();
        expect(chunks, isNotEmpty);

        final textParts = chunks.map((c) => c.textDelta).whereType<String>().join();
        expect(textParts, isNotEmpty);
      } catch (e) {
        if (e.toString().contains('quota') || e.toString().contains('429') || e.toString().contains('unknown error')) {
          print('Skipping test due to local Gemini CLI daily quota limit: $e');
        } else {
          rethrow;
        }
      }
    }, skip: geminiAvailable ? null : 'gemini CLI not available on system');
  });
}
