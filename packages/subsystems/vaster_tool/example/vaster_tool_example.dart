import 'package:vaster_model/vaster_model.dart';
import 'package:vaster_tool/vaster_tool.dart';

void main() async {
  print('=== Vaster Executable Tool Example ===');

  final tool = FunctionTool.define(
    name: 'calculate_tax',
    description: 'Calculates sales tax for an amount.',
    parametersSchema: {
      'type': 'object',
      'properties': {
        'amount': {'type': 'number'},
        'rate': {'type': 'number'},
      },
    },
    handler: (args) {
      final amount = (args['amount'] as num? ?? 0).toDouble();
      final rate = (args['rate'] as num? ?? 0.20).toDouble();
      return {'tax': amount * rate, 'total': amount * (1 + rate)};
    },
  );

  print('Tool Descriptor: ${tool.descriptor}');

  final result = await tool.execute(
    const FunctionCallPart(
      callId: 'call_tax_01',
      name: 'calculate_tax',
      arguments: {'amount': 100.0, 'rate': 0.24},
    ),
  );

  print('Execution Result: ${result.response}');
}
