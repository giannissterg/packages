import 'sandbox_descriptor.dart';
import 'sandbox_request.dart';
import 'sandbox_result.dart';
import 'sandbox_security_policy.dart';

/// Abstract interface class defining an isolated code sandbox backend.
abstract interface class CodeSandbox {
  /// Descriptor metadata handle.
  SandboxDescriptor get descriptor;

  /// Default security policy configured for this sandbox instance.
  SandboxSecurityPolicy get defaultPolicy;

  /// Executes a [SandboxRequest] inside this sandbox environment.
  Future<SandboxResult> run(SandboxRequest request);
}
