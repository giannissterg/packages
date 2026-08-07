/// Outcome kind of a policy authorization check.
enum PolicyDecisionKind {
  allow('allow'),
  deny('deny'),
  requiresHumanApproval('requires_human_approval');

  final String name;
  const PolicyDecisionKind(this.name);

  static PolicyDecisionKind parse(String value) {
    final lower = value.toLowerCase().trim();
    for (final k in PolicyDecisionKind.values) {
      if (k.name == lower) return k;
    }
    return PolicyDecisionKind.deny;
  }
}

/// Result of evaluating an authorization request against an [ExecutionPolicy].
class PolicyDecision {
  final PolicyDecisionKind kind;
  final String reason;

  const PolicyDecision._(this.kind, this.reason);

  const factory PolicyDecision.allow([String reason]) = _AllowDecision;
  const factory PolicyDecision.deny([String reason]) = _DenyDecision;
  const factory PolicyDecision.requiresApproval([String reason]) = _RequiresApprovalDecision;

  bool get isAllowed => kind == PolicyDecisionKind.allow;
  bool get isDenied => kind == PolicyDecisionKind.deny;
  bool get isRequiresApproval => kind == PolicyDecisionKind.requiresHumanApproval;

  Map<String, dynamic> toJson() => {'kind': kind.name, 'reason': reason};

  factory PolicyDecision.fromJson(Map<String, dynamic> json) {
    final kind = PolicyDecisionKind.parse(json['kind'] as String? ?? '');
    final reason = json['reason'] as String? ?? '';
    return switch (kind) {
      PolicyDecisionKind.allow => PolicyDecision.allow(reason),
      PolicyDecisionKind.deny => PolicyDecision.deny(reason),
      PolicyDecisionKind.requiresHumanApproval => PolicyDecision.requiresApproval(reason),
    };
  }

  @override
  String toString() => 'PolicyDecision.${kind.name}("$reason")';
}

class _AllowDecision extends PolicyDecision {
  const _AllowDecision([String reason = 'Operation authorized by policy.'])
    : super._(PolicyDecisionKind.allow, reason);
}

class _DenyDecision extends PolicyDecision {
  const _DenyDecision([String reason = 'Operation denied by policy.'])
    : super._(PolicyDecisionKind.deny, reason);
}

class _RequiresApprovalDecision extends PolicyDecision {
  const _RequiresApprovalDecision([String reason = 'Operation requires human approval.'])
    : super._(PolicyDecisionKind.requiresHumanApproval, reason);
}
