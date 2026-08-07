import 'dart:async';

import 'package:vaster_model/vaster_model.dart';

import 'executable_tool_interface.dart';
import 'tool_descriptor.dart';
import 'tool_result.dart';

/// Standard implementation of [ExecutableTool] wrapping a Dart function handler.
class FunctionTool implements ExecutableTool {
  @override
  final ToolDescriptor descriptor;

  final FutureOr<Map<String, dynamic>> Function(Map<String, dynamic> arguments) handler;

  FunctionTool({required this.descriptor, required this.handler});

  /// Factory helper to build a [FunctionTool] concisely.
  factory FunctionTool.define({
    required String name,
    required String description,
    Map<String, dynamic> parametersSchema = const {'type': 'object', 'properties': {}},
    required FutureOr<Map<String, dynamic>> Function(Map<String, dynamic> args) handler,
  }) {
    return FunctionTool(
      descriptor: ToolDescriptor(name: name, description: description, parametersSchema: parametersSchema),
      handler: handler,
    );
  }

  @override
  ToolDefinition get definition => descriptor.toDefinition();

  @override
  String get name => descriptor.name;

  @override
  Future<ToolResult> execute(FunctionCallPart callPart) async {
    final watch = Stopwatch()..start();
    try {
      final res = await handler(callPart.arguments);
      watch.stop();
      return ToolResult(
        callId: callPart.callId,
        name: callPart.name,
        response: res,
        executionDuration: watch.elapsed,
      );
    } catch (e, st) {
      watch.stop();
      return ToolResult(
        callId: callPart.callId,
        name: callPart.name,
        response: {'error': e.toString()},
        isError: true,
        errorDetails: '$e\n$st',
        executionDuration: watch.elapsed,
      );
    }
  }
}
