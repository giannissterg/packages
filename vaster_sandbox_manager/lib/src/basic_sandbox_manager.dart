import 'package:vaster_sandbox/vaster_sandbox.dart';
import 'package:vaster_tool/vaster_tool.dart';
import 'sandbox_manager_interface.dart';

/// Standard implementation of [SandboxManager].
class BasicSandboxManager implements SandboxManager {
  final Map<String, CodeSandbox> _sandboxes = {};

  BasicSandboxManager({List<CodeSandbox> sandboxes = const []}) {
    for (final s in sandboxes) {
      registerSandbox(s);
    }
  }

  @override
  List<SandboxDescriptor> get activeDescriptors =>
      List.unmodifiable(_sandboxes.values.map((s) => s.descriptor));

  @override
  void registerSandbox(CodeSandbox sandbox) {
    _sandboxes[sandbox.descriptor.sandboxId] = sandbox;
  }

  @override
  bool unregisterSandbox(String sandboxId) {
    return _sandboxes.remove(sandboxId) != null;
  }

  @override
  CodeSandbox? getSandbox(String sandboxId) {
    return _sandboxes[sandboxId];
  }

  @override
  Future<SandboxResult> runCode({
    required String sandboxId,
    required String codeOrCommand,
    SandboxLanguage language = SandboxLanguage.dart,
    Map<String, dynamic> inputs = const {},
  }) async {
    final sandbox = getSandbox(sandboxId);
    if (sandbox == null) {
      return SandboxResult(
        exitCode: 1,
        stdout: '',
        stderr: 'Sandbox "$sandboxId" not registered.',
        executionTime: Duration.zero,
        securityViolation: true,
      );
    }

    return await sandbox.run(SandboxRequest(
      codeOrCommand: codeOrCommand,
      language: language,
      inputs: inputs,
    ));
  }

  @override
  ExecutableTool createSandboxTool({
    required String sandboxId,
    String toolName = 'execute_sandbox_code',
    String description = 'Executes code inside an isolated sandbox environment.',
  }) {
    final sandbox = getSandbox(sandboxId);
    if (sandbox == null) {
      throw StateError('Cannot create tool: Sandbox "$sandboxId" is not registered.');
    }

    return FunctionTool.define(
      name: toolName,
      description: description,
      parametersSchema: {
        'type': 'object',
        'properties': {
          'code': {'type': 'string', 'description': 'Code or command to execute'},
          'language': {'type': 'string', 'description': 'Language / runtime'},
        },
      },
      handler: (args) async {
        final code = args['code'] as String? ?? '';
        final langStr = args['language'] as String? ?? 'dart';
        final result = await runCode(
          sandboxId: sandboxId,
          codeOrCommand: code,
          language: SandboxLanguage.parse(langStr),
        );
        return result.toJson();
      },
    );
  }
}
