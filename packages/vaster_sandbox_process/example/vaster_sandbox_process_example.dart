import 'package:vaster_sandbox/vaster_sandbox.dart';
import 'package:vaster_sandbox_process/vaster_sandbox_process.dart';

void main() async {
  print('=== Vaster Process Sandbox Backend Example ===');

  final sandbox = ProcessCodeSandbox();
  final result = await sandbox.run(const SandboxRequest(
    codeOrCommand: 'echo Hello Process Sandbox',
    language: SandboxLanguage.bash,
  ));

  print('Process Output: ${result.stdout}');
}
