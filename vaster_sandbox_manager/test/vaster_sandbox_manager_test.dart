import 'package:test/test.dart';
import 'package:vaster_model/vaster_model.dart';
import 'package:vaster_sandbox_isolate/vaster_sandbox_isolate.dart';
import 'package:vaster_sandbox_manager/vaster_sandbox_manager.dart';

void main() {
  group('BasicSandboxManager', () {
    test('registers sandbox backend and runs code', () async {
      final SandboxManager manager = BasicSandboxManager();
      final sandbox = IsolateCodeSandbox(
        descriptor: const SandboxDescriptor(
          sandboxId: 'sb_1',
          type: 'isolate',
          description: 'Isolate SB',
        ),
        evaluator: (code, inputs) => 'eval_ok',
      );

      manager.registerSandbox(sandbox);
      expect(manager.activeDescriptors, hasLength(1));
      expect(manager.getSandbox('sb_1'), equals(sandbox));

      final result = await manager.runCode(
        sandboxId: 'sb_1',
        codeOrCommand: 'testCode()',
      );
      expect(result.isSuccess, isTrue);
      expect(result.resultValue, equals('eval_ok'));
    });

    test('creates ExecutableTool and executes code via tool call', () async {
      final manager = BasicSandboxManager();
      manager.registerSandbox(IsolateCodeSandbox(
        descriptor: const SandboxDescriptor(
          sandboxId: 'dart_runner',
          type: 'isolate',
          description: 'Dart Runner',
        ),
        evaluator: (code, inputs) => {'status': 'success'},
      ));

      final tool = manager.createSandboxTool(sandboxId: 'dart_runner');
      expect(tool.name, equals('execute_sandbox_code'));

      const callPart = FunctionCallPart(
        callId: 'call_sb_1',
        name: 'execute_sandbox_code',
        arguments: {'code': 'print("hi")'},
      );

      final toolResult = await tool.execute(callPart);
      expect(toolResult.isError, isFalse);
      expect(toolResult.response['exitCode'], equals(0));
    });
  });
}
