import 'package:test/test.dart';
import 'package:vaster_sandbox/vaster_sandbox.dart';
import 'package:vaster_sandbox_isolate/vaster_sandbox_isolate.dart';

void main() {
  group('IsolateCodeSandbox', () {
    test('runs code inside Isolate and returns result', () async {
      final sandbox = IsolateCodeSandbox(
        evaluator: (code, inputs) => {'sum': (inputs['a'] as int) + (inputs['b'] as int)},
      );

      final result = await sandbox.run(
        const SandboxRequest(codeOrCommand: 'add(a, b)', inputs: {'a': 10, 'b': 20}),
      );

      expect(result.isSuccess, isTrue);
      expect(result.resultValue, equals({'sum': 30}));
    });

    test('times out when isolate execution exceeds policy maxTimeout', () async {
      final sandbox = IsolateCodeSandbox(
        defaultPolicy: const SandboxSecurityPolicy(maxTimeout: Duration(milliseconds: 100)),
        evaluator: (code, inputs) async {
          await Future.delayed(const Duration(milliseconds: 500));
          return 'done';
        },
      );

      final result = await sandbox.run(const SandboxRequest(codeOrCommand: 'slowTask()'));

      expect(result.timedOut, isTrue);
      expect(result.isSuccess, isFalse);
    });
  });
}
