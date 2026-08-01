import 'package:test/test.dart';
import 'package:vaster_sandbox/vaster_sandbox.dart';

void main() {
  group('SandboxDescriptor & Request & Result & SecurityPolicy', () {
    test('SandboxDescriptor json roundtrip', () {
      const descriptor = SandboxDescriptor(
        sandboxId: 'isolate_1',
        type: 'isolate',
        description: 'Dart Isolate Sandbox',
        supportedLanguages: ['dart'],
      );

      final json = descriptor.toJson();
      final restored = SandboxDescriptor.fromJson(json);

      expect(restored.sandboxId, equals('isolate_1'));
      expect(restored.type, equals('isolate'));
      expect(restored.supportedLanguages, equals(['dart']));
    });

    test('SandboxSecurityPolicy defaults and json roundtrip', () {
      const policy = SandboxSecurityPolicy(
        maxTimeout: Duration(seconds: 15),
        allowNetwork: false,
      );

      final json = policy.toJson();
      final restored = SandboxSecurityPolicy.fromJson(json);

      expect(restored.maxTimeout, equals(const Duration(seconds: 15)));
      expect(restored.allowNetwork, isFalse);
    });

    test('SandboxResult isSuccess evaluation', () {
      const successResult = SandboxResult(
        exitCode: 0,
        stdout: 'Success output',
        stderr: '',
        executionTime: Duration(milliseconds: 50),
      );
      expect(successResult.isSuccess, isTrue);

      const timeoutResult = SandboxResult(
        exitCode: 1,
        stdout: '',
        stderr: 'Timeout',
        executionTime: Duration(seconds: 30),
        timedOut: true,
      );
      expect(timeoutResult.isSuccess, isFalse);
    });
  });
}
