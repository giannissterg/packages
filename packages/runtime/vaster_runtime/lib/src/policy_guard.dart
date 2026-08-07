import 'package:vaster_policy/vaster_policy.dart';
import 'package:vaster_policy_engine/vaster_policy_engine.dart';
import 'package:vaster_tool/vaster_tool.dart';

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
final class PolicyGuard implements ToolCallGate {
  final PolicyEngine engine;
  final ExecutionPolicy policy;

  const PolicyGuard({required this.engine, required this.policy});

  /// [ToolCallGate]: the program's policy gates a tool call (A1 — the
  /// runtime binds this guard into the VM's agent gate binding, so
  /// AGENT-internal tool calls answer to the same program policy the ISA
  /// loop enforces). Throws [PolicyViolationException] — uncatchable.
  @override
  String permit(String toolName) {
    check(PolicyAction.toolCall, toolName);
    return toolName;
  }

  /// Authorizes [action] on [resource] and echoes the resource (Rule 11);
  /// throws [PolicyViolationException] on denial.
  String check(PolicyAction action, String resource) {
    final decision = engine.authorize(policy: policy, action: action, resource: resource);
    if (decision.isDenied) {
      throw PolicyViolationException(action: action, resource: resource, reason: decision.reason);
    }
    return resource;
  }
}
