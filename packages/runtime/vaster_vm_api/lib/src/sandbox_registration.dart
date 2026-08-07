import 'package:vaster_sandbox/vaster_sandbox.dart';
import 'package:vaster_tool/vaster_tool.dart';

/// What registering a sandbox displaced — BOTH registries the bridge
/// writes (sandbox table + bridged executable tool). The old anonymous
/// record named its field `sandbox:`, which read as the registered one;
/// these names say what they hold (Rule 11).
final class SandboxRegistration {
  /// The sandbox previously registered under the same id, null when fresh.
  final CodeSandbox? displacedSandbox;

  /// The tool previously registered under the bridged `exec_<id>` name.
  final ExecutableTool? displacedBridgedTool;

  const SandboxRegistration({required this.displacedSandbox, required this.displacedBridgedTool});

  /// Nothing displaced — both registrations were fresh.
  static const fresh = SandboxRegistration(displacedSandbox: null, displacedBridgedTool: null);

  @override
  String toString() =>
      'SandboxRegistration('
      'sandbox ${displacedSandbox == null ? 'fresh' : 'displaced'}, '
      'bridged tool ${displacedBridgedTool == null ? 'fresh' : 'displaced'})';
}
