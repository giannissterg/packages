import 'package:vaster_policy/vaster_policy.dart';

/// Master interface defining policy evaluation and hierarchical policy derivation.
abstract interface class PolicyEngine {
  /// Evaluates whether [action] on [resource] is authorized under [policy].
  PolicyDecision authorize({
    required ExecutionPolicy policy,
    required PolicyAction action,
    required String resource,
    Map<String, dynamic> context = const {},
  });

  /// Derives a child policy from [parentPolicy], ensuring the child
  /// policy can only restrict (narrow) capabilities, never expand them.
  ExecutionPolicy deriveChildPolicy({
    required ExecutionPolicy parentPolicy,
    required ExecutionPolicy requestedChildPolicy,
  });
}
