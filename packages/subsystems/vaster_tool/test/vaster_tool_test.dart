import 'package:test/test.dart';
import 'package:vaster_model/vaster_model.dart';
import 'package:vaster_tool/vaster_tool.dart';

void main() {
  group('FunctionTool & ToolDescriptor & ToolResult', () {
    test('ToolDescriptor converts to ToolDefinition', () {
      const descriptor = ToolDescriptor(
        name: 'add_numbers',
        description: 'Adds two numbers',
        parametersSchema: {
          'type': 'object',
          'properties': {
            'a': {'type': 'number'},
            'b': {'type': 'number'},
          },
        },
      );

      final def = descriptor.toDefinition();
      expect(def.name, equals('add_numbers'));
      expect(def.description, equals('Adds two numbers'));
    });

    test('FunctionTool defines and executes function calls', () async {
      final tool = FunctionTool.define(
        name: 'multiply',
        description: 'Multiplies two numbers',
        handler: (args) {
          final a = args['a'] as num? ?? 0;
          final b = args['b'] as num? ?? 0;
          return {'result': a * b};
        },
      );

      const callPart = FunctionCallPart(callId: 'call_123', name: 'multiply', arguments: {'a': 6, 'b': 7});

      final result = await tool.execute(callPart);
      expect(result.callId, equals('call_123'));
      expect(result.name, equals('multiply'));
      expect(result.isError, isFalse);
      expect(result.response['result'], equals(42));

      final chatMsg = result.toChatMessage();
      expect(chatMsg.role, equals(Role.tool));
      expect(chatMsg.functionResponses.first.response['result'], equals(42));
    });

    test('FunctionTool catches error during execution', () async {
      final tool = FunctionTool.define(
        name: 'failing_tool',
        description: 'Always throws an error',
        handler: (args) {
          throw Exception('Tool operation failed');
        },
      );

      const callPart = FunctionCallPart(callId: 'call_err', name: 'failing_tool', arguments: {});

      final result = await tool.execute(callPart);
      expect(result.isError, isTrue);
      expect(result.errorDetails, contains('Tool operation failed'));
      expect(result.response['error'], contains('Tool operation failed'));
    });
  });
}
