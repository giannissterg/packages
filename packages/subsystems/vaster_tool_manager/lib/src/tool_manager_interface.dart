import 'package:vaster_model/vaster_model.dart';
import 'package:vaster_tool/vaster_tool.dart';

/// Interface defining the runtime tool registry and execution dispatcher.
abstract interface class ToolManager {
  /// Unmodifiable view of active tool descriptors.
  List<ToolDescriptor> get activeDescriptors;

  /// Unmodifiable view of registered tools.
  List<ExecutableTool> get registeredTools;

  /// Compiles all registered tools into a list of [ToolDefinition]s for inclusion in [ModelRequest].
  List<ToolDefinition> get compiledDefinitions;

  /// Registers an executable tool.
  /// Returns the same-name tool it displaced, null when fresh (a silent
  /// override is observable — Rule 11).
  ExecutableTool? registerTool(ExecutableTool tool);

  /// Unregisters a tool by name.
  bool unregisterTool(String name);

  /// Retrieves an executable tool by name.
  ExecutableTool? getTool(String name);

  /// Executes a single [FunctionCallPart].
  Future<ToolResult> executeCall(FunctionCallPart callPart);

  /// Dispatches multiple [FunctionCallPart]s and converts outputs into a list of [ChatMessage] tool responses.
  Future<List<ChatMessage>> processFunctionCalls(Iterable<FunctionCallPart> calls);
}
