import 'package:test/test.dart';
import 'package:vaster_sandbox/vaster_sandbox.dart';
import 'package:vaster_sandbox_ffi/vaster_sandbox_ffi.dart';

void main() {
  group('Native Dynamic Library FFI Execution Sandbox (vaster_sandbox_ffi)', () {
    late FfiCodeSandbox sandbox;

    setUp(() {
      sandbox = FfiCodeSandbox();
    });

    test('FfiCodeSandbox initializes with default descriptor and security policy', () {
      expect(sandbox.descriptor.type, equals('ffi'));
      expect(sandbox.descriptor.supportedLanguages, contains(SandboxLanguage.custom));
      expect(sandbox.defaultPolicy.maxTimeout, equals(const Duration(seconds: 5)));
    });

    test('FfiCodeSandbox handles missing library gracefully with exit code 1', () async {
      final request = const SandboxRequest(
        codeOrCommand: '/path/to/non_existent_library.dylib',
        language: SandboxLanguage.custom,
        inputs: {'symbol': 'c_main'},
      );

      final result = await sandbox.run(request);
      expect(result.exitCode, equals(1));
      expect(result.stderr, contains('Failed to open native dynamic library'));
      expect(result.isSuccess, isFalse);
    });

    test('FfiCodeSandbox handles invalid symbol gracefully with exit code 1', () async {
      // System dynamic library available on macOS/Linux
      final libPath = '/usr/lib/libSystem.B.dylib';

      final request = SandboxRequest(
        codeOrCommand: libPath,
        language: SandboxLanguage.custom,
        inputs: {'symbol': 'non_existent_vaster_symbol_xyz'},
      );

      final result = await sandbox.run(request);
      expect(result.exitCode, equals(1));
      expect(result.stderr, contains('Failed to lookup or execute symbol'));
      expect(result.isSuccess, isFalse);
    });
  });
}
