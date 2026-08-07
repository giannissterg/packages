import 'package:test/test.dart';
import 'package:vaster_sandbox/vaster_sandbox.dart';
import 'package:vaster_sandbox_process/vaster_sandbox_process.dart';

void main() {
  group('ProcessCodeSandbox', () {
    test('runs echo command and captures stdout', () async {
      final sandbox = ProcessCodeSandbox();
      final result = await sandbox.run(
        const SandboxRequest(codeOrCommand: 'echo HelloProcessSandbox', language: SandboxLanguage.bash),
      );

      expect(result.isSuccess, isTrue);
      expect(result.stdout, contains('HelloProcessSandbox'));
    });

    test('enforces command whitelist security policy', () async {
      final sandbox = ProcessCodeSandbox(
        defaultPolicy: const SandboxSecurityPolicy(allowedCommands: ['echo', 'ls']),
      );

      final result = await sandbox.run(
        const SandboxRequest(codeOrCommand: 'rm -rf /tmp/test', language: SandboxLanguage.bash),
      );

      expect(result.securityViolation, isTrue);
      expect(result.isSuccess, isFalse);
      expect(result.stderr, contains('blocked by security policy'));
    });
  });
}
