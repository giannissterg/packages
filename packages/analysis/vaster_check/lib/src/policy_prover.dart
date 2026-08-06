import 'package:vaster_instruction/vaster_instruction.dart';
import 'package:vaster_policy/vaster_policy.dart';

import 'check_finding.dart';
import 'control_flow_graph.dart';
import 'definite_assignment.dart';

/// Static policy verification: prove that no reachable instruction can
/// violate the declared [ExecutionPolicy].
///
/// - A statically-known resource (no `${...}`) that the policy denies is a
///   **proven violation** — the program WILL trap; fail before running it.
/// - An interpolated resource is **unprovable**: reported as a warning so
///   the reader knows the runtime gate is the only defense there.
/// - A clean report means: every reachable policy-checked instruction with a
///   static resource is allowed, and no dynamic resources exist — a proof.
///
/// The decision procedure mirrors the runtime engine's exactly:
/// denied capabilities win, then allowed, then [ExecutionPolicy.defaultAllow].
final class PolicyProver {
  final ExecutionPolicy policy;

  const PolicyProver(this.policy);

  bool _allows(PolicyAction action, String resource) {
    for (final c in policy.deniedCapabilities) {
      if (c.matches(action, resource)) return false;
    }
    for (final c in policy.allowedCapabilities) {
      if (c.matches(action, resource)) return true;
    }
    return policy.defaultAllow;
  }

  List<CheckFinding> analyze(ControlFlowGraph cfg) {
    final findings = <CheckFinding>[];
    final reachable = cfg.reachable();
    final instructions = cfg.program.instructions;

    void checkStatic(int pc, PolicyAction action, String resource) {
      if (DefiniteAssignment.interpolationReads(resource).isNotEmpty) {
        findings.add(PolicyUnprovable(
            action: action.name, resourceTemplate: resource, pc: pc));
        return;
      }
      if (!_allows(action, resource)) {
        findings.add(PolicyViolationProven(
            action: action.name, resource: resource, pc: pc));
      }
    }

    for (var pc = 0; pc < instructions.length; pc++) {
      if (!reachable.contains(pc)) continue;
      switch (instructions[pc]) {
        case WriteFileOp op:
          checkStatic(pc, PolicyAction.fileWrite, op.vfsPath);
        case ReadFileOp op:
          checkStatic(pc, PolicyAction.fileRead, op.vfsPath);
        case ExecSandboxOp op:
          checkStatic(pc, PolicyAction.sandboxExec, op.sandboxId);
        case CheckPolicyOp op:
          // The program's own explicit gate: resources here are never
          // interpolated by spec.
          checkStatic(pc, op.action, op.resource);
        default:
          break;
      }
    }
    return findings;
  }
}
