/// Static verification for compiled Vaster programs.
///
/// Three analyses over the ISA control-flow graph, none of which need the
/// frontend or a running VM:
/// - **Binding dominance** — every register read is dominated by a write on
///   every path (definite assignment, not the flat liveness heuristic).
/// - **Cost bounds** — worst-case token/cost estimate from loop trip counts,
///   agent loop ceilings, and the pricing catalog: "this program costs at
///   most ~$X" before running it.
/// - **Policy proofs** — prove no reachable instruction can violate a
///   declared `ExecutionPolicy`; dynamic (interpolated) resources are
///   reported as unprovable rather than assumed safe.
library;

export 'src/check_finding.dart';
export 'src/check_report.dart';
export 'src/control_flow_graph.dart';
export 'src/cost_bound.dart';
export 'src/definite_assignment.dart';
export 'src/policy_prover.dart';
export 'src/program_checker.dart';
