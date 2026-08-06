import 'policy_action.dart';

/// A declared execution policy denied an action — **uncatchable by
/// design**: program error handlers (`TryCatch`, `Resilient`) never see
/// it and retries never re-attempt it; the machine traps. Typed so the
/// security boundary is a type check, not a message-prefix match.
final class PolicyViolationException implements Exception {
  final PolicyAction action;
  final String resource;
  final String reason;

  const PolicyViolationException({
    required this.action,
    required this.resource,
    required this.reason,
  });

  @override
  String toString() => 'Policy violation: $reason';
}
