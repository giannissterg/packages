import 'dart:async';
import 'dart:ffi';

import 'package:vaster_cancellation/vaster_cancellation.dart';
import 'package:vaster_sandbox/vaster_sandbox.dart';

/// Function signature for native C functions returning an int32 exit code.
typedef NativeIntFunction = Int32 Function();
typedef DartIntFunction = int Function();

/// Native C/C++/Rust Dynamic Library implementation of [CodeSandbox] using `dart:ffi`.
///
/// Loads compiled `.dylib` / `.so` / `.dll` native shared libraries into memory
/// and executes native C/Rust functions directly with nanosecond performance and
/// timeout watchdog protection.
class FfiCodeSandbox implements CodeSandbox {
  @override
  final SandboxDescriptor descriptor;

  @override
  final SandboxSecurityPolicy defaultPolicy;

  FfiCodeSandbox({
    this.descriptor = const SandboxDescriptor(
      sandboxId: 'ffi_default',
      type: 'ffi',
      description: 'Native C/C++/Rust Dynamic Library Sandbox',
      supportedLanguages: [SandboxLanguage.custom],
    ),
    this.defaultPolicy = const SandboxSecurityPolicy(
      maxTimeout: Duration(seconds: 5),
      allowNetwork: false,
    ),
  });

  @override
  Future<SandboxResult> run(
    SandboxRequest request, {
    CancellationToken? cancelToken,
  }) async {
    cancelToken?.throwIfCancelled();
    final policy = request.securityPolicy ?? defaultPolicy;
    final watch = Stopwatch()..start();

    final libraryPath = request.codeOrCommand;
    final symbolName = request.inputs['symbol'] as String? ?? 'vaster_main';

    try {
      final Future<SandboxResult> execFuture = Future(() {
        DynamicLibrary library;
        try {
          library = DynamicLibrary.open(libraryPath);
        } catch (e, st) {
          return SandboxResult.failure(
            exitCode: 1,
            stderr: 'Failed to open native dynamic library at "$libraryPath": $e',
            executionTime: watch.elapsed,
            errorDetails: SandboxErrorDetails(
              exceptionType: e.runtimeType.toString(),
              stackTrace: st.toString(),
            ),
          );
        }

        try {
          final nativeFn = library.lookupFunction<NativeIntFunction, DartIntFunction>(symbolName);
          final exitCode = nativeFn();
          watch.stop();

          if (exitCode == 0) {
            return SandboxResult.success(
              stdout: 'Native FFI symbol "$symbolName" executed cleanly from "$libraryPath".',
              executionTime: watch.elapsed,
              resultValue: {'symbol': symbolName, 'library': libraryPath, 'exitCode': exitCode},
              metrics: SandboxMetrics(cpuTime: watch.elapsed),
            );
          }

          return SandboxResult.failure(
            exitCode: exitCode,
            stderr: 'Native FFI symbol "$symbolName" returned non-zero exit code ($exitCode).',
            executionTime: watch.elapsed,
          );
        } catch (e, st) {
          watch.stop();
          return SandboxResult.failure(
            exitCode: 1,
            stderr: 'Failed to lookup or execute symbol "$symbolName" in "$libraryPath": $e',
            executionTime: watch.elapsed,
            errorDetails: SandboxErrorDetails(
              exceptionType: e.runtimeType.toString(),
              stackTrace: st.toString(),
            ),
          );
        }
      });

      final result = await execFuture.timeout(policy.maxTimeout);
      cancelToken?.throwIfCancelled();
      return result;
    } on TimeoutException {
      watch.stop();
      return SandboxResult.timeout(
        maxTimeout: policy.maxTimeout,
        executionTime: watch.elapsed,
      );
    } catch (e, st) {
      watch.stop();
      return SandboxResult.failure(
        exitCode: 1,
        stderr: 'FFI sandbox execution error: $e',
        executionTime: watch.elapsed,
        errorDetails: SandboxErrorDetails(
          exceptionType: e.runtimeType.toString(),
          stackTrace: st.toString(),
        ),
      );
    }
  }
}
