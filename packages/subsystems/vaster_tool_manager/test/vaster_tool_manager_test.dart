import 'package:test/test.dart';
import 'package:vaster_model/vaster_model.dart';
import 'package:vaster_tool_manager/vaster_tool_manager.dart';

void main() {
  group('BasicToolManager', () {
    test('registerTool returns the tool it displaced (Rule 11)', () {
      final manager = BasicToolManager();
      final first = FunctionTool.define(
        name: 't',
        description: 'v1',
        parametersSchema: const {},
        handler: (_) => {'v': 1},
      );
      expect(manager.registerTool(first), isNull, reason: 'fresh registration displaces nothing');
      final displaced = manager.registerTool(
        FunctionTool.define(
          name: 't',
          description: 'v2',
          parametersSchema: const {},
          handler: (_) => {'v': 2},
        ),
      );
      expect(displaced, same(first), reason: 'a silent override is observable now');
    });

    test('registers tools and compiles ToolDefinitions for ModelRequest', () {
      final ToolManager manager = BasicToolManager();

      manager.registerTool(
        FunctionTool.define(name: 'calc_sum', description: 'Calculates sum', handler: (args) => {'sum': 42}),
      );

      expect(manager.registeredTools, hasLength(1));
      expect(manager.activeDescriptors.first.name, equals('calc_sum'));
      expect(manager.compiledDefinitions.first.name, equals('calc_sum'));
    });

    test('dispatches function call and returns tool response ChatMessage', () async {
      final manager = BasicToolManager(
        tools: [
          FunctionTool.define(
            name: 'get_weather',
            description: 'Gets current weather',
            handler: (args) => {'location': args['location'], 'temp': '22C'},
          ),
        ],
      );

      const call = FunctionCallPart(
        callId: 'call_weather_1',
        name: 'get_weather',
        arguments: {'location': 'Athens'},
      );

      final messages = await manager.processFunctionCalls([call]);
      expect(messages, hasLength(1));
      expect(messages.first.role, equals(Role.tool));

      final resPart = messages.first.functionResponses.first;
      expect(resPart.callId, equals('call_weather_1'));
      expect(resPart.response['temp'], equals('22C'));
    });

    test('returns error ToolResult when invoking unknown tool', () async {
      final manager = BasicToolManager();

      const call = FunctionCallPart(callId: 'call_unknown', name: 'missing_tool', arguments: {});

      final result = await manager.executeCall(call);
      expect(result.isError, isTrue);
      expect(result.response['error'], contains('not found'));
    });
  });
}
