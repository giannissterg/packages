import 'package:vaster_policy/vaster_policy.dart';
import 'package:vaster_policy_engine/vaster_policy_engine.dart';

/// Immutable policy-enforcement collaborator.
///
/// Binds one [ExecutionPolicy] to one [PolicyEngine] for the lifetime of a
/// runtime and turns denials into VM security traps. Both the fetch-decode
/// engine and the tool-call orchestrator compose this guard rather than each
/// re-implementing the check — the security boundary lives in exactly one
/// place.
///
/// Policy violations are deliberately thrown as [StateError]s prefixed with
/// `Policy violation` — the run loop treats that prefix as uncatchable by
/// program-level `TryCatch` handlers.
final class PolicyGuard {
  final PolicyEngine engine;
  final ExecutionPolicy policy;

  const PolicyGuard({required this.engine, required this.policy});

  /// Authorizes [action] on [resource]; throws a `Policy violation`
  /// [StateError] on denial.
  void check(PolicyAction action, String resource) {
    final decision = engine.authorize(
      policy: policy,
      action: action,
      resource: resource,
    );
    if (decision.isDenied) {
      throw PolicyViolationException(
        action: action,
        resource: resource,
        reason: decision.reason,
      );
    }
  }
}
