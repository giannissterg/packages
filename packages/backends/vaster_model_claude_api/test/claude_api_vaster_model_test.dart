import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:test/test.dart';
import 'package:vaster_model/vaster_model.dart';
import 'package:vaster_model_claude_api/vaster_model_claude_api.dart';

void main() {
  group('Request lowering (Vaster contract -> Messages API)', () {
    test('lowers system, messages, tools, and max_tokens', () {
      final request = ModelRequest(
        systemInstruction: ChatMessage.system('You are terse.'),
        messages: [ChatMessage.user('hello')],
        tools: const [
          ToolDefinition(
            name: 'read_file',
            description: 'Read a VFS file',
            parametersSchema: {
              'type': 'object',
              'properties': {
                'path': {'type': 'string'},
              },
              'required': ['path'],
            },
          ),
        ],
      );

      final body = ClaudeApiVasterModel.buildRequestBody(
        request,
        model: 'claude-opus-5',
      );

      expect(body['model'], equals('claude-opus-5'));
      expect(body['max_tokens'], equals(16000));
      expect((body['system'] as List).single['text'], equals('You are terse.'));
      expect(body['messages'], hasLength(1));
      final tool = (body['tools'] as List).single as Map;
      expect(tool['name'], equals('read_file'));
      expect(tool['input_schema'], containsPair('type', 'object'));
      // Sampling params never forwarded — modern models reject them.
      expect(body.containsKey('temperature'), isFalse);
    });

    test('tool round-trip: model tool_use turn and tool_result turn', () {
      final messages = [
        ChatMessage.user('read main.dart'),
        const ChatMessage(role: Role.model, parts: [
          TextPart('Reading the file.'),
          FunctionCallPart(
            callId: 'toolu_01',
            name: 'read_file',
            arguments: {'path': '/mem/main.dart'},
          ),
        ]),
        ChatMessage.toolResponse('toolu_01', 'read_file', {'content': 'void main() {}'}),
      ];

      final lowered = ClaudeApiVasterModel.lowerMessages(messages);

      expect(lowered, hasLength(3));
      final assistant = lowered[1];
      expect(assistant['role'], equals('assistant'));
      final toolUse = (assistant['content'] as List)[1] as Map;
      expect(toolUse['type'], equals('tool_use'));
      expect(toolUse['id'], equals('toolu_01'));
      expect(toolUse['input'], equals({'path': '/mem/main.dart'}));

      final toolTurn = lowered[2];
      expect(toolTurn['role'], equals('user'));
      final result = (toolTurn['content'] as List).single as Map;
      expect(result['type'], equals('tool_result'));
      expect(result['tool_use_id'], equals('toolu_01'));
      expect(jsonDecode(result['content'] as String), equals({'content': 'void main() {}'}));
    });

    test('responseSchema lowers to structured outputs', () {
      final request = ModelRequest(
        messages: [ChatMessage.user('extract the name')],
        generationConfig: const GenerationConfig(
          responseSchema: {
            'type': 'object',
            'properties': {
              'name': {'type': 'string'},
            },
            'required': ['name'],
            'additionalProperties': false,
          },
        ),
      );

      final body =
          ClaudeApiVasterModel.buildRequestBody(request, model: 'claude-opus-5');

      final format = (body['output_config'] as Map)['format'] as Map;
      expect(format['type'], equals('json_schema'));
      expect((format['schema'] as Map)['required'], equals(['name']));
    });

    test('cache hints lower to cache_control breakpoints', () {
      final request = ModelRequest(
        systemInstruction: ChatMessage.system('Big stable prompt'),
        messages: [
          ChatMessage.user('turn 1'),
          ChatMessage.model('answer 1'),
          ChatMessage.user('turn 2'),
        ],
        cacheHints: const [
          ContextCacheHint(
            regionId: 'sys',
            contentFingerprint: 'abc123',
            ttl: Duration(hours: 2),
          ),
        ],
      );

      final body =
          ClaudeApiVasterModel.buildRequestBody(request, model: 'claude-opus-5');

      // Breakpoint on the system block (stable prefix; long TTL honored).
      final system = (body['system'] as List).single as Map;
      expect(system['cache_control'], equals({'type': 'ephemeral', 'ttl': '1h'}));

      // Breakpoint on the last block of the previous turn, not the live question.
      final messages = body['messages'] as List;
      final previousTurn = messages[messages.length - 2] as Map;
      final lastBlock = (previousTurn['content'] as List).last as Map;
      expect(lastBlock['cache_control'], isNotNull);
      final liveTurn = messages.last as Map;
      final liveBlock = (liveTurn['content'] as List).last as Map;
      expect(liveBlock.containsKey('cache_control'), isFalse);
    });

    test('no cache hints -> no cache_control anywhere', () {
      final request = ModelRequest(
        systemInstruction: ChatMessage.system('prompt'),
        messages: [ChatMessage.user('q')],
      );
      final body =
          ClaudeApiVasterModel.buildRequestBody(request, model: 'claude-opus-5');
      expect(jsonEncode(body).contains('cache_control'), isFalse);
    });

    test('strict tools inject additionalProperties and required', () {
      const tool = ToolDefinition(
        name: 'exec',
        description: 'Run code',
        parametersSchema: {
          'type': 'object',
          'properties': {
            'code': {'type': 'string'},
          },
        },
      );

      final lowered = ClaudeApiVasterModel.lowerTool(tool, strict: true);
      expect(lowered['strict'], isTrue);
      final schema = lowered['input_schema'] as Map;
      expect(schema['additionalProperties'], isFalse);
      expect(schema['required'], equals(['code']));
    });
  });

  group('Response parsing (Messages API -> Vaster contract)', () {
    test('parses text + exact usage', () {
      final response = ClaudeApiVasterModel.parseResponse({
        'content': [
          {'type': 'text', 'text': 'Hello from Claude'},
        ],
        'stop_reason': 'end_turn',
        'usage': {'input_tokens': 120, 'output_tokens': 8},
      });

      expect(response.text, equals('Hello from Claude'));
      expect(response.finishReason, equals(FinishReason.stop));
      expect(response.usage.promptTokenCount, equals(120));
      expect(response.usage.candidatesTokenCount, equals(8));
    });

    test('cache reads/writes are charged into prompt tokens', () {
      final response = ClaudeApiVasterModel.parseResponse({
        'content': [
          {'type': 'text', 'text': 'ok'},
        ],
        'stop_reason': 'end_turn',
        'usage': {
          'input_tokens': 40,
          'cache_read_input_tokens': 900,
          'cache_creation_input_tokens': 60,
          'output_tokens': 5,
        },
      });

      // 40 uncached + 900 cache-read + 60 cache-write = 1000 real prompt tokens.
      expect(response.usage.promptTokenCount, equals(1000));
    });

    test('parses tool_use into FunctionCallPart', () {
      final response = ClaudeApiVasterModel.parseResponse({
        'content': [
          {'type': 'text', 'text': 'Let me check.'},
          {
            'type': 'tool_use',
            'id': 'toolu_abc',
            'name': 'write_file',
            'input': {'path': '/mem/a.txt', 'content': 'hi'},
          },
        ],
        'stop_reason': 'tool_use',
        'usage': {'input_tokens': 10, 'output_tokens': 20},
      });

      expect(response.finishReason, equals(FinishReason.toolCalls));
      final call = response.functionCalls.single;
      expect(call.callId, equals('toolu_abc'));
      expect(call.name, equals('write_file'));
      expect(call.arguments['path'], equals('/mem/a.txt'));
    });

    test('refusal maps to FinishReason.safety', () {
      final response = ClaudeApiVasterModel.parseResponse({
        'content': [],
        'stop_reason': 'refusal',
        'usage': {'input_tokens': 10, 'output_tokens': 0},
      });
      expect(response.finishReason, equals(FinishReason.safety));
    });

    test('stop reason mapping table', () {
      expect(ClaudeApiVasterModel.mapStopReason('end_turn'), FinishReason.stop);
      expect(ClaudeApiVasterModel.mapStopReason('max_tokens'), FinishReason.maxTokens);
      expect(ClaudeApiVasterModel.mapStopReason('tool_use'), FinishReason.toolCalls);
      expect(ClaudeApiVasterModel.mapStopReason('pause_turn'), FinishReason.toolCalls);
      expect(ClaudeApiVasterModel.mapStopReason('refusal'), FinishReason.safety);
      expect(ClaudeApiVasterModel.mapStopReason(null), FinishReason.unknown);
    });

    test('parseUsage carries the cache breakdown and measured source', () {
      final usage = ClaudeApiVasterModel.parseUsage({
        'input_tokens': 6,
        'cache_read_input_tokens': 4000,
        'cache_creation_input_tokens': 500,
        'output_tokens': 300,
      });
      expect(usage.promptTokenCount, equals(4506));
      expect(usage.cacheReadTokenCount, equals(4000));
      expect(usage.cacheCreationTokenCount, equals(500));
      expect(usage.source, equals(UsageSource.measured));
    });
  });

  group('SSE streaming usage', () {
    test('message_start seeds input+cache; message_delta supplies output', () async {
      // Anthropic reports input/cache counts only in message_start; the
      // message_delta usage carries cumulative output_tokens. The terminal
      // chunk must merge both — before this fix, streamed prompt tokens ≈ 0.
      final events = [
        {
          'type': 'message_start',
          'message': {
            'usage': {
              'input_tokens': 12,
              'cache_read_input_tokens': 2000,
              'cache_creation_input_tokens': 300,
              'output_tokens': 1,
            },
          },
        },
        {
          'type': 'content_block_delta',
          'delta': {'type': 'text_delta', 'text': 'Hello'},
        },
        {
          'type': 'message_delta',
          'delta': {'stop_reason': 'end_turn'},
          'usage': {'output_tokens': 42},
        },
        {'type': 'message_stop'},
      ];
      final sse = events.map((e) => 'data: ${jsonEncode(e)}\n\n').join();

      final model = ClaudeApiVasterModel(
        apiKey: 'test-key',
        clientFactory: () => _FakeSseClient(sse),
      );

      final chunks = await model
          .generateStream(ModelRequest(messages: [ChatMessage.user('hi')]))
          .toList();

      final terminal = chunks.last;
      expect(terminal.finishReason, equals(FinishReason.stop));
      expect(terminal.usage, isNotNull);
      expect(terminal.usage!.promptTokenCount, equals(12 + 2000 + 300));
      expect(terminal.usage!.cacheReadTokenCount, equals(2000));
      expect(terminal.usage!.cacheCreationTokenCount, equals(300));
      expect(terminal.usage!.candidatesTokenCount, equals(42));
      expect(terminal.usage!.source, equals(UsageSource.measured));
    });
  });
}

/// Serves a canned SSE body for any request.
class _FakeSseClient extends http.BaseClient {
  final String body;
  _FakeSseClient(this.body);

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    return http.StreamedResponse(
      Stream.value(utf8.encode(body)),
      200,
    );
  }
}
