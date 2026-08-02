import 'package:vaster_sandbox/vaster_sandbox.dart';
import 'package:vaster_sandbox_isolate/vaster_sandbox_isolate.dart';

void main() async {
  print('=== Vaster Isolate Sandbox Backend Example ===');

  final sandbox = IsolateCodeSandbox(
    evaluator: (code, inputs) => 'Executed: $code',
  );

  final result = await sandbox.run(const SandboxRequest(
    codeOrCommand: 'main()',
  ));

  print('Isolate Result: ${result.stdout}');
}
