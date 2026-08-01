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
    this.defaultPolicy = const SandboxSecurityPolicy(
      maxTimeout: Duration(seconds: 30),
      allowNetwork: false,
    ),
    this.workingDirectory,
  });

  @override
  Future<SandboxResult> run(
    SandboxRequest request, {
    CancellationToken? cancelToken,
  }) async {
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
    if (policy.allowedCommands != null &&
        !policy.allowedCommands!.contains(executable)) {
      return SandboxResult(
        exitCode: 126,
        stdout: '',
        stderr: 'Command "$executable" is blocked by security policy.',
        executionTime: Duration.zero,
        securityViolation: true,
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

      return SandboxResult(
        exitCode: processResult.exitCode,
        stdout: processResult.stdout.toString(),
        stderr: processResult.stderr.toString(),
        executionTime: watch.elapsed,
      );
    } on TimeoutException {
      watch.stop();
      return SandboxResult(
        exitCode: 124,
        stdout: '',
        stderr: 'Process execution timed out after ${policy.maxTimeout.inSeconds} seconds.',
        executionTime: watch.elapsed,
        timedOut: true,
      );
    } catch (e, st) {
      watch.stop();
      return SandboxResult(
        exitCode: 1,
        stdout: '',
        stderr: 'Process error: $e\n$st',
        executionTime: watch.elapsed,
      );
    }
  }
}
