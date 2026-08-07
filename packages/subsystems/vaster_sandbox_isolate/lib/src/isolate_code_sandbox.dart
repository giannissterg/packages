import 'dart:async';
import 'dart:isolate';

import 'package:vaster_model/vaster_model.dart';
import 'package:vaster_sandbox/vaster_sandbox.dart';

/// Dart Isolate implementation of [CodeSandbox] for running Dart execution routines
/// in a separate memory isolate with timeout protection.
class IsolateCodeSandbox implements CodeSandbox {
  @override
  final SandboxDescriptor descriptor;

  @override
  final SandboxSecurityPolicy defaultPolicy;

  /// Custom handler to evaluate input code or function payload inside an isolate context.
  final FutureOr<Object?> Function(String code, Map<String, dynamic> inputs)? evaluator;

  IsolateCodeSandbox({
    this.descriptor = const SandboxDescriptor(
      sandboxId: 'isolate_default',
      type: 'isolate',
      description: 'Dart Isolate Code Sandbox',
      supportedLanguages: [SandboxLanguage.dart],
    ),
    this.defaultPolicy = const SandboxSecurityPolicy(maxTimeout: Duration(seconds: 10), allowNetwork: false),
    this.evaluator,
  });

  @override
  Future<SandboxResult> run(SandboxRequest request, {CancellationToken? cancelToken}) async {
    cancelToken?.throwIfCancelled();
    final policy = request.securityPolicy ?? defaultPolicy;
    final watch = Stopwatch()..start();

    try {
      final FutureOr<Object?> Function(String, Map<String, dynamic>) evalFn = evaluator ?? _defaultEvaluator;

      final Future<Object?> isolateFuture = Isolate.run<Object?>(() async {
        return await evalFn(request.codeOrCommand, request.inputs);
      });

      final resultVal = await isolateFuture.timeout(policy.maxTimeout);
      watch.stop();

      cancelToken?.throwIfCancelled();

      return SandboxResult.success(
        stdout: 'Isolate execution completed.\nResult: $resultVal',
        executionTime: watch.elapsed,
        resultValue: resultVal,
        metrics: SandboxMetrics(cpuTime: watch.elapsed),
      );
    } on TimeoutException {
      watch.stop();
      return SandboxResult.timeout(maxTimeout: policy.maxTimeout, executionTime: watch.elapsed);
    } catch (e, st) {
      watch.stop();
      return SandboxResult.failure(
        exitCode: 1,
        stderr: 'Isolate execution error: $e',
        executionTime: watch.elapsed,
        errorDetails: SandboxErrorDetails(exceptionType: e.runtimeType.toString(), stackTrace: st.toString()),
      );
    }
  }

  static Object? _defaultEvaluator(String code, Map<String, dynamic> inputs) {
    return {'status': 'executed', 'codeLength': code.length, 'receivedInputs': inputs};
  }
}
