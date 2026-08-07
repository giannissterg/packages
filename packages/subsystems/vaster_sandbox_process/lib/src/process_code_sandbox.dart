import 'dart:async';
import 'dart:io';

import 'package:vaster_model/vaster_model.dart';
import 'package:vaster_sandbox/vaster_sandbox.dart';

/// CLI Process implementation of [CodeSandbox] for running system commands/scripts
/// with process timeouts, stdout/stderr capture, and environment variable filtering.
class ProcessCodeSandbox implements CodeSandbox {
  @override
  final SandboxDescriptor descriptor;

  @override
  final SandboxSecurityPolicy defaultPolicy;

  final String? workingDirectory;

  ProcessCodeSandbox({
    this.descriptor = const SandboxDescriptor(
      sandboxId: 'process_default',
      type: 'process',
      description: 'CLI Process Code Sandbox',
      supportedLanguages: [
        SandboxLanguage.bash,
        SandboxLanguage.sh,
        SandboxLanguage.dart,
        SandboxLanguage.python,
      ],
    ),
    this.defaultPolicy = const SandboxSecurityPolicy(maxTimeout: Duration(seconds: 30), allowNetwork: false),
    this.workingDirectory,
  });

  @override
  Future<SandboxResult> run(SandboxRequest request, {CancellationToken? cancelToken}) async {
    cancelToken?.throwIfCancelled();
    final policy = request.securityPolicy ?? defaultPolicy;
    final watch = Stopwatch()..start();

    final cmd = request.codeOrCommand.trim();
    if (cmd.isEmpty) {
      return SandboxResult(
        exitCode: 1,
        stdout: '',
        stderr: 'Empty command string',
        executionTime: Duration.zero,
      );
    }

    final parts = cmd.split(' ');
    final executable = parts.first;
    final args = parts.skip(1).toList();

    // Check command whitelist if policy specifies allowedCommands
    if (policy.allowedCommands != null && !policy.allowedCommands!.contains(executable)) {
      return SandboxResult.securityViolation(
        violatedRule: SecurityViolationRule.allowedCommands,
        executionTime: Duration.zero,
        stderr: 'Command "$executable" is blocked by security policy.',
      );
    }

    // Filter environment variables according to policy whitelist
    final env = <String, String>{};
    if (policy.environmentWhitelist.isNotEmpty) {
      final hostEnv = Platform.environment;
      for (final key in policy.environmentWhitelist) {
        if (hostEnv.containsKey(key)) {
          env[key] = hostEnv[key]!;
        }
      }
    }
    env.addAll(request.environment);

    try {
      final processResult = await Process.run(
        executable,
        args,
        workingDirectory: workingDirectory,
        environment: env,
      ).timeout(policy.maxTimeout);

      watch.stop();
      cancelToken?.throwIfCancelled();

      if (processResult.exitCode == 0) {
        return SandboxResult.success(
          stdout: processResult.stdout.toString(),
          executionTime: watch.elapsed,
          metrics: SandboxMetrics(cpuTime: watch.elapsed),
        );
      }

      return SandboxResult.failure(
        exitCode: processResult.exitCode,
        stdout: processResult.stdout.toString(),
        stderr: processResult.stderr.toString(),
        executionTime: watch.elapsed,
      );
    } on TimeoutException {
      watch.stop();
      return SandboxResult.timeout(maxTimeout: policy.maxTimeout, executionTime: watch.elapsed);
    } catch (e, st) {
      watch.stop();
      return SandboxResult.failure(
        exitCode: 1,
        stderr: 'Process error: $e',
        executionTime: watch.elapsed,
        errorDetails: SandboxErrorDetails(exceptionType: e.runtimeType.toString(), stackTrace: st.toString()),
      );
    }
  }
}
