import 'capability.dart';
import 'policy_action.dart';

/// Container of allowed and denied capabilities governing an execution scope.
class ExecutionPolicy {
  final String policyId;
  final List<Capability> allowedCapabilities;
  final List<Capability> deniedCapabilities;

  /// Fallback behavior if no capability matches an authorization check.
  final bool defaultAllow;

  const ExecutionPolicy({
    required this.policyId,
    this.allowedCapabilities = const [],
    this.deniedCapabilities = const [],
    this.defaultAllow = false,
  });

  /// Canonical unlimited policy allowing all actions unconditionally.
  static const unlimited = ExecutionPolicy(policyId: 'unlimited', defaultAllow: true);

  /// Canonical read-only policy allowing reading files and executing models,
  /// but denying file writes, file deletes, and sandbox execution.
  static final readOnly = ExecutionPolicy(
    policyId: 'read_only',
    allowedCapabilities: [
      Capability.any(PolicyAction.fileRead),
      Capability.any(PolicyAction.modelGenerate),
      Capability.any(PolicyAction.humanInteraction),
    ],
    deniedCapabilities: [
      Capability.any(PolicyAction.fileWrite),
      Capability.any(PolicyAction.fileDelete),
      Capability.any(PolicyAction.sandboxExec),
    ],
    defaultAllow: false,
  );

  Map<String, dynamic> toJson() => {
    'policyId': policyId,
    'allowedCapabilities': allowedCapabilities.map((c) => c.toJson()).toList(),
    'deniedCapabilities': deniedCapabilities.map((c) => c.toJson()).toList(),
    'defaultAllow': defaultAllow,
  };

  factory ExecutionPolicy.fromJson(Map<String, dynamic> json) {
    return ExecutionPolicy(
      policyId: json['policyId'] as String? ?? 'custom',
      allowedCapabilities: (json['allowedCapabilities'] as List? ?? [])
          .whereType<Map<String, dynamic>>()
          .map((c) => Capability.fromJson(c))
          .toList(),
      deniedCapabilities: (json['deniedCapabilities'] as List? ?? [])
          .whereType<Map<String, dynamic>>()
          .map((c) => Capability.fromJson(c))
          .toList(),
      defaultAllow: json['defaultAllow'] as bool? ?? false,
    );
  }
}
