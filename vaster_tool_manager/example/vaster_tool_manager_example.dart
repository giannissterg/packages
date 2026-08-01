import 'package:vaster_model/vaster_model.dart';
import 'package:vaster_tool_manager/vaster_tool_manager.dart';

void main() async {
  print('=== Vaster Tool Manager Example ===');

  final ToolManager manager = BasicToolManager();

  manager.registerTool(FunctionTool.define(
    name: 'read_workspace_file',
    description: 'Reads text file content.',
    handler: (args) => {'content': 'ideas.md file contents...'},
  ));

  print('Compiled Tool Definitions for ModelRequest: ${manager.compiledDefinitions}');

  final toolResponseMessages = await manager.processFunctionCalls([
    const FunctionCallPart(
      callId: 'call_rf_1',
      name: 'read_workspace_file',
      arguments: {'path': 'ideas.md'},
    ),
  ]);

  print('Tool Response Turn: ${toolResponseMessages.first.text}');

  print('Done!');
}
