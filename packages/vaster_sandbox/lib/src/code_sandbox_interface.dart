import 'package:vaster_model/vaster_model.dart';
import 'sandbox_descriptor.dart';
import 'sandbox_request.dart';
import 'sandbox_result.dart';
import 'sandbox_security_policy.dart';

/// Pure abstract interface defining an isolated code execution environment.
abstract interface class CodeSandbox {
  /// Metadata handle identifying this sandbox.
  SandboxDescriptor get descriptor;

  /// Default security policy enforced by this sandbox backend.
  SandboxSecurityPolicy get defaultPolicy;

  /// Executes code or commands inside the isolated sandbox environment.
  Future<SandboxResult> run(
    SandboxRequest request, {
    CancellationToken? cancelToken,
  });
}
