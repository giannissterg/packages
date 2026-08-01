import 'package:vaster_sandbox/vaster_sandbox.dart';
import 'package:vaster_tool/vaster_tool.dart';

/// Interface defining the runtime sandbox manager and tool bridge.
abstract interface class SandboxManager {
  /// Unmodifiable view of active sandbox descriptors.
  List<SandboxDescriptor> get activeDescriptors;

  /// Registers a [CodeSandbox] backend instance.
  void registerSandbox(CodeSandbox sandbox);

  /// Unregisters a sandbox backend by ID.
  bool unregisterSandbox(String sandboxId);

  /// Retrieves a registered [CodeSandbox] by ID.
  CodeSandbox? getSandbox(String sandboxId);

  /// Executes code on target sandbox by ID.
  Future<SandboxResult> runCode({
    required String sandboxId,
    required String codeOrCommand,
    String language = 'dart',
    Map<String, dynamic> inputs = const {},
  });

  /// Automatically bridges a registered sandbox into an [ExecutableTool] for `vaster_tool_manager`.
  ExecutableTool createSandboxTool({
    required String sandboxId,
    String toolName = 'execute_sandbox_code',
    String description = 'Executes code inside an isolated sandbox environment.',
  });
}
