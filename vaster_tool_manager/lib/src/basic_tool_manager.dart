import 'package:vaster_model/vaster_model.dart';
import 'package:vaster_tool/vaster_tool.dart';
import 'tool_manager_interface.dart';

/// Standard implementation of [ToolManager].
class BasicToolManager implements ToolManager {
  final Map<String, ExecutableTool> _tools = {};

  BasicToolManager({List<ExecutableTool> tools = const []}) {
    for (final t in tools) {
      registerTool(t);
    }
  }

  @override
  List<ExecutableTool> get registeredTools =>
      List.unmodifiable(_tools.values);

  @override
  List<ToolDescriptor> get activeDescriptors =>
      List.unmodifiable(_tools.values.map((t) => t.descriptor));

  @override
  List<ToolDefinition> get compiledDefinitions =>
      List.unmodifiable(_tools.values.map((t) => t.definition));

  @override
  void registerTool(ExecutableTool tool) {
    _tools[tool.name] = tool;
  }

  @override
  bool unregisterTool(String name) {
    return _tools.remove(name) != null;
  }

  @override
  ExecutableTool? getTool(String name) {
    return _tools[name];
  }

  @override
  Future<ToolResult> executeCall(FunctionCallPart callPart) async {
    final tool = getTool(callPart.name);
    if (tool == null) {
      return ToolResult(
        callId: callPart.callId,
        name: callPart.name,
        response: {'error': 'Tool "${callPart.name}" not found.'},
        isError: true,
        errorDetails: 'No tool registered with name "${callPart.name}".',
      );
    }

    return await tool.execute(callPart);
  }

  @override
  Future<List<ChatMessage>> processFunctionCalls(
    Iterable<FunctionCallPart> calls,
  ) async {
    final responses = <ChatMessage>[];
    for (final call in calls) {
      final result = await executeCall(call);
      responses.add(result.toChatMessage());
    }
    return responses;
  }
}
