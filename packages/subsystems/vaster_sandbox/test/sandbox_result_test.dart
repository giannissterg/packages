import 'package:test/test.dart';
import 'package:vaster_sandbox/vaster_sandbox.dart';

void main() {
  group('Enriched SandboxResult Entity Model', () {
    test('SandboxResult.success named constructor creates success result with metrics', () {
      final res = SandboxResult.success(
        stdout: 'Build completed successfully.',
        executionTime: const Duration(milliseconds: 150),
        resultValue: {'outputBinary': 'bin/main'},
        metrics: const SandboxMetrics(peakMemoryBytes: 1024 * 1024 * 16),
      );

      expect(res.isSuccess, isTrue);
      expect(res.status, equals(SandboxExecutionStatus.success));
      expect(res.exitCode, equals(0));
      expect(res.stdout, equals('Build completed successfully.'));
      expect(res.metrics.peakMemoryBytes, equals(16 * 1024 * 1024));
    });

    test('SandboxResult.timeout named constructor creates timeout result', () {
      final res = SandboxResult.timeout(
        maxTimeout: const Duration(seconds: 10),
        executionTime: const Duration(seconds: 10),
      );

      expect(res.isSuccess, isFalse);
      expect(res.status, equals(SandboxExecutionStatus.timedOut));
      expect(res.exitCode, equals(124));
      expect(res.timedOut, isTrue);
      expect(res.errorDetails?.violatedRule, equals(SecurityViolationRule.maxTimeout));
    });

    test('SandboxResult.securityViolation named constructor creates violation result', () {
      final res = SandboxResult.securityViolation(
        violatedRule: SecurityViolationRule.allowNetwork,
        executionTime: const Duration(milliseconds: 5),
        stderr: 'Network access blocked by policy.',
      );

      expect(res.isSuccess, isFalse);
      expect(res.status, equals(SandboxExecutionStatus.securityViolation));
      expect(res.securityViolation, isTrue);
      expect(res.errorDetails?.violatedRule, equals(SecurityViolationRule.allowNetwork));
    });

    test('SandboxResult json roundtrip preserves enriched metrics and status', () {
      final res = SandboxResult.success(
        stdout: 'Processed text',
        executionTime: const Duration(milliseconds: 45),
        metrics: const SandboxMetrics(peakMemoryBytes: 2048, cpuTime: Duration(milliseconds: 30)),
      );

      final json = res.toJson();
      final restored = SandboxResult.fromJson(json);

      expect(restored.status, equals(SandboxExecutionStatus.success));
      expect(restored.exitCode, equals(0));
      expect(restored.metrics.peakMemoryBytes, equals(2048));
      expect(restored.metrics.cpuTime?.inMilliseconds, equals(30));
    });
  });
}
