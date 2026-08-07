import 'package:vaster_events/vaster_events.dart';
import 'package:vaster_policy/vaster_policy.dart';

import 'policy_engine_interface.dart';

/// Concrete implementation of [PolicyEngine] providing policy evaluation,
/// event bus telemetry, and strict hierarchical policy containment.
class BasicPolicyEngine implements PolicyEngine {
  final RuntimeEventBus? eventBus;

  BasicPolicyEngine({this.eventBus});

  @override
  PolicyDecision authorize({
    required ExecutionPolicy policy,
    required PolicyAction action,
    required String resource,
    Map<String, dynamic> context = const {},
  }) {
    // 1. Deny overrides allow: check explicit denial rules first
    for (final c in policy.deniedCapabilities) {
      if (c.matches(action, resource)) {
        final decision = PolicyDecision.deny(
          'Denied by explicit denial rule for action "$action" on "$resource".',
        );
        _publishTelemetry(policy, action, resource, decision);
        return decision;
      }
    }

    // 2. Check explicit allow rules
    for (final c in policy.allowedCapabilities) {
      if (c.matches(action, resource)) {
        final decision = PolicyDecision.allow(
          'Authorized by explicit capability for action "$action" on "$resource".',
        );
        _publishTelemetry(policy, action, resource, decision);
        return decision;
      }
    }

    // 3. Default fallback decision
    final decision = policy.defaultAllow
        ? const PolicyDecision.allow('Authorized by default-allow policy fallback.')
        : PolicyDecision.deny('Denied by default-deny policy fallback for action "$action" on "$resource".');

    _publishTelemetry(policy, action, resource, decision);
    return decision;
  }

  @override
  ExecutionPolicy deriveChildPolicy({
    required ExecutionPolicy parentPolicy,
    required ExecutionPolicy requestedChildPolicy,
  }) {
    // 1. Child allowed capabilities must also be authorized by parent
    final constrainedAllowed = requestedChildPolicy.allowedCapabilities
        .where((cap) => _isCapabilityAllowedByParent(parentPolicy, cap))
        .toList();

    // 2. Denials accumulate: parent denials + child denials
    final combinedDenied = <Capability>{
      ...parentPolicy.deniedCapabilities,
      ...requestedChildPolicy.deniedCapabilities,
    }.toList();

    // 3. Default allow is narrowed (true only if both parent and child allow)
    final childDefaultAllow = parentPolicy.defaultAllow && requestedChildPolicy.defaultAllow;

    return ExecutionPolicy(
      policyId: '${parentPolicy.policyId}_child_${requestedChildPolicy.policyId}',
      allowedCapabilities: constrainedAllowed,
      deniedCapabilities: combinedDenied,
      defaultAllow: childDefaultAllow,
    );
  }

  bool _isCapabilityAllowedByParent(ExecutionPolicy parentPolicy, Capability cap) {
    // Check if parent explicitly denies this capability's pattern
    for (final d in parentPolicy.deniedCapabilities) {
      if (d.action == cap.action && d.pattern == cap.pattern) {
        return false;
      }
    }
    // If parent is defaultAllow, or parent explicitly grants cap, it passes
    if (parentPolicy.defaultAllow) return true;
    for (final a in parentPolicy.allowedCapabilities) {
      if (a.action == cap.action && a.pattern == cap.pattern) {
        return true;
      }
    }
    return false;
  }

  /// Returns the published event's id, null when no bus is wired.
  String? _publishTelemetry(
    ExecutionPolicy policy,
    PolicyAction action,
    String resource,
    PolicyDecision decision,
  ) {
    return eventBus?.publish(
      PolicyEvaluatedEvent(
        eventId: 'evt_policy_eval_${DateTime.now().microsecondsSinceEpoch}',
        policyId: policy.policyId,
        action: action.name,
        resource: resource,
        decision: decision.kind.name,
        reason: decision.reason,
      ),
    );
  }
}
