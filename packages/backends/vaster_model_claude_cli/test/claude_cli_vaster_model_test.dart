import 'package:test/test.dart';
import 'package:vaster_model/vaster_model.dart';
import 'package:vaster_model_claude_cli/vaster_model_claude_cli.dart';

void main() {
  group('ClaudeCliVasterModel.parseCliJson', () {
    test('parses a successful result with usage', () {
      const stdout = '{"type":"result","subtype":"success","is_error":false,'
          '"result":"pong","session_id":"abc",'
          '"usage":{"input_tokens":11,"output_tokens":3}}';

      final response = ClaudeCliVasterModel.parseCliJson(stdout);

      expect(response.text, equals('pong'));
      expect(response.finishReason, equals(FinishReason.stop));
      expect(response.usage.promptTokenCount, equals(11));
      expect(response.usage.candidatesTokenCount, equals(3));
    });

    test('cache tokens fold into prompt count and cost is captured', () {
      // Shape observed live: on a warm cache input_tokens is single digits
      // while the cached prefix carries the real prompt size.
      const stdout = '{"type":"result","is_error":false,"result":"ok",'
          '"total_cost_usd":0.0234,'
          '"usage":{"input_tokens":6,"output_tokens":700,'
          '"cache_read_input_tokens":4200,"cache_creation_input_tokens":800},'
          '"modelUsage":{"claude-opus-5":{"inputTokens":6,"costUSD":0.0234}}}';

      final response = ClaudeCliVasterModel.parseCliJson(stdout);

      expect(response.usage.promptTokenCount, equals(6 + 4200 + 800));
      expect(response.usage.cacheReadTokenCount, equals(4200));
      expect(response.usage.cacheCreationTokenCount, equals(800));
      expect(response.usage.candidatesTokenCount, equals(700));
      expect(response.usage.costUsd, equals(0.0234));
      expect(response.usage.source, equals(UsageSource.measured));
      // The full CLI JSON (modelUsage breakdown etc.) is preserved raw.
      expect(response.rawResponse, isA<Map<String, dynamic>>());
      expect((response.rawResponse as Map)['modelUsage'], isNotNull);
    });

    test('throws StateError when the CLI reports is_error', () {
      // This is the real payload emitted by an unauthenticated CLI.
      const stdout = '{"type":"result","subtype":"success","is_error":true,'
          '"result":"Not logged in · Please run /login","usage":{}}';

      expect(
        () => ClaudeCliVasterModel.parseCliJson(stdout),
        throwsA(isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('Not logged in'),
        )),
      );
    });

    test('tolerates leading/trailing non-JSON noise', () {
      const stdout = 'warning: something\n'
          '{"is_error":false,"result":"ok","usage":{"input_tokens":1,"output_tokens":1}}\n';

      expect(ClaudeCliVasterModel.parseCliJson(stdout).text, equals('ok'));
    });

    test('throws FormatException when no JSON is present', () {
      expect(
        () => ClaudeCliVasterModel.parseCliJson('command not found'),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('ClaudeCliVasterModel.composePrompt', () {
    test('flattens conversation turns and omits the system instruction', () {
      final request = ModelRequest(
        systemInstruction: ChatMessage.system('be terse'),
        messages: [
          ChatMessage.user('hello'),
          ChatMessage.model('hi'),
          ChatMessage.user('who are you?'),
        ],
      );

      final prompt = ClaudeCliVasterModel.composePrompt(request);

      expect(prompt, contains('user: hello'));
      expect(prompt, contains('model: hi'));
      expect(prompt, contains('user: who are you?'));
      expect(prompt, isNot(contains('be terse')));
    });
  });

  test('exposes Claude-appropriate capabilities', () {
    final model = ClaudeCliVasterModel();
    expect(model.modelName, equals('claude-cli'));
    expect(model.capabilities.maxContextTokens, equals(200000));
    expect(model.capabilities.supportsFunctionCalling, isFalse);
    expect(model.capabilities.supportsSystemInstruction, isTrue);
  });
}
