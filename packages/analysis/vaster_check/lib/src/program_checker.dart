import 'package:vaster_instruction/vaster_instruction.dart';
import 'package:vaster_policy/vaster_policy.dart';
import 'package:vaster_pricing/vaster_pricing.dart';
import 'package:vaster_token_estimate/vaster_token_estimate.dart';

import 'check_finding.dart';
import 'check_report.dart';
import 'control_flow_graph.dart';
import 'cost_bound.dart';
import 'definite_assignment.dart';
import 'policy_prover.dart';

/// The static verifier: one call, three analyses, a sealed report.
final class ProgramChecker {
  final PricingCatalog pricingCatalog;

  /// Policy to prove against; null skips policy analysis.
  final ExecutionPolicy? policy;

  /// Model the cost bound is rated against. Null derives the most expensive
  /// model the program can select — fallback-chain members included
  /// ([mostExpensiveSelectableModel]); a tokens-only bound only when nothing
  /// in the program rates against the catalog.
  final String? modelName;

  /// Per-call response allowance for the cost bound.
  final int responseAllowanceTokens;

  /// See [CostAnalyzer.estimator] / [CostAnalyzer.callOverheadFactor] —
  /// pass-throughs so hosts compose calibration without touching the
  /// analyzer directly.
  final TokenEstimator estimator;
  final double callOverheadFactor;

  const ProgramChecker({
    required this.pricingCatalog,
    this.policy,
    this.modelName,
    this.responseAllowanceTokens = 1024,
    this.estimator = const HeuristicTokenEstimator(),
    this.callOverheadFactor = 1.0,
  });

  CheckReport check(VasterProgram program) {
    final cfg = ControlFlowGraph.of(program);
    final findings = <CheckFinding>[];

    // Unreachable code (info-level, from the shared CFG).
    final reachable = cfg.reachable();
    for (var pc = 0; pc < program.instructions.length; pc++) {
      if (!reachable.contains(pc)) {
        findings.add(UnreachableInstruction(
            pc: pc, opcode: program.instructions[pc].opcode.name));
      }
    }

    findings.addAll(DefiniteAssignment(cfg).analyze());

    // No caller-supplied rated model → derive it from the program itself:
    // the most expensive model any SelectModelOp can reach, INCLUDING
    // fallback-chain members (REL-P3). Declared resilience is priced at
    // its worst member, exactly as the analyzer's docs promise.
    final ratedModel =
        modelName ?? mostExpensiveSelectableModel(program, pricingCatalog);
    final (costBound, costFindings) = CostAnalyzer(
      pricingCatalog: pricingCatalog,
      modelName: ratedModel,
      responseAllowanceTokens: responseAllowanceTokens,
      estimator: estimator,
      callOverheadFactor: callOverheadFactor,
    ).analyze(cfg);
    findings.addAll(costFindings);

    final activePolicy = policy;
    if (activePolicy != null) {
      findings.addAll(PolicyProver(activePolicy).analyze(cfg));
    }

    findings.sort((a, b) {
      final bySeverity = a.severity.index.compareTo(b.severity.index);
      if (bySeverity != 0) return bySeverity;
      return (a.pc ?? -1).compareTo(b.pc ?? -1);
    });
    return CheckReport(findings: findings, costBound: costBound);
  }
}
