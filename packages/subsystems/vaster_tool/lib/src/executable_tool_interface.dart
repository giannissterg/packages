import 'package:vaster_model/vaster_model.dart';
import 'tool_descriptor.dart';
import 'tool_result.dart';

/// Abstract interface class for an executable tool binding.
abstract interface class ExecutableTool {
  /// Tool descriptor metadata handle.
  ToolDescriptor get descriptor;

  /// Convenience getter returning [ToolDefinition] for `vaster_model`.
  ToolDefinition get definition => descriptor.toDefinition();

  /// Tool name.
  String get name => descriptor.name;

  /// Executes this tool against incoming [FunctionCallPart] arguments.
  Future<ToolResult> execute(FunctionCallPart callPart);
}
