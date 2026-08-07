import 'package:vaster_instruction/vaster_instruction.dart';
import 'package:vaster_model/vaster_model.dart';
import 'package:vaster_pricing/vaster_pricing.dart';
import 'package:vaster_token_estimate/vaster_token_estimate.dart';

import 'check_finding.dart';
import 'control_flow_graph.dart';

/// The static worst-case cost of one program.
final class CostBound {
  /// Worst-case model calls (loop-multiplied; agent dispatches count their
  /// descriptor's tool-loop ceiling).
  final int maxModelCalls;

  /// Worst-case token estimate across those calls (prompt estimates plus the
  /// per-call response allowance).
  final int maxTokens;

  /// Worst-case cost when [maxTokens] is bounded and the model is priced;
  /// null when unpriceable.
  final double? maxCostUsd;

  /// True when an unbounded loop contains a model call — [maxTokens] and
  /// [maxCostUsd] then cover only the bounded portion.
  final bool unbounded;

  const CostBound({
    required this.maxModelCalls,
    required this.maxTokens,
    required this.maxCostUsd,
    required this.unbounded,
  });

  Map<String, dynamic> toJson() => {
    'maxModelCalls': maxModelCalls,
    'maxTokens': maxTokens,
    if (maxCostUsd != null) 'maxCostUsd': maxCostUsd,
    'unbounded': unbounded,
  };
}

/// The most expensive model the program can reach — `SelectModelOp`
/// primaries AND fallback-chain members (REL-P3), plus agent-declared
/// models and their chains on `CreateAgentOp` descriptors (GAP-3b): a
/// declared chain can serve any call under its scope from any member, so
/// the honest single rate is the worst one. Ranked by combined per-MTok
/// rate (input + output); members the catalog cannot price are skipped.
/// Null when nothing rates — the bound then stays honestly tokens-only.
String? mostExpensiveSelectableModel(VasterProgram program, PricingCatalog catalog) {
  String? costliest;
  double costliestRate = -1;
  void consider(ModelDescriptor descriptor) {
    final pricing = catalog.lookup(descriptor.modelId);
    if (pricing == null) return;
    final rate = pricing.inputUsdPerMTok + pricing.outputUsdPerMTok;
    if (rate > costliestRate) {
      costliestRate = rate;
      costliest = descriptor.modelId;
    }
  }

  for (final op in program.instructions) {
    switch (op) {
      case SelectModelOp(:final descriptor, :final fallbacks):
        [descriptor, ...fallbacks].forEach(consider);
      case CreateAgentOp(descriptor: final agent) when agent.modelDescriptor != null:
        [agent.modelDescriptor!, ...agent.modelFallbacks].forEach(consider);
      default:
        break;
    }
  }
  return costliest;
}

/// Worst-case cost analysis: loop trip counts × per-call estimates × rates.
///
/// Loop bounds are recognized from the compiler's canonical shape — a
/// counter initialized to a constant, compared `lt` against a constant
/// (`CompareRegisterOp`) guarding the back-edge region. Every While/Repeat/
/// DecideLoop the compiler emits carries such a guard (`maxIterations` is
/// compiled in); a back-edge with no recognizable guard is reported as
/// [UnboundedLoop] and makes the bound honest about being partial.
final class CostAnalyzer {
  final PricingCatalog pricingCatalog;

  /// Token estimation seam — the canonical heuristic by default, a
  /// calibrated (or exact) estimator when the host composes one in
  /// (`vaster_calibration` profiles are paired with backends by the CLI,
  /// never here: the analyzer knows the seam, not the profiles).
  final TokenEstimator estimator;

  /// Whole-call overhead multiplier for backends whose harness does work
  /// beyond the visible prompt (CLI-agentic backends explore the repo in
  /// their own loop — the prove-it run measured the API-shaped bound low
  /// by 2.23x). `1.0` = the bound models API-shaped calls, as before.
  final double callOverheadFactor;

  /// Model the program is rated against (SelectModelOp switching is folded
  /// conservatively into this single rate — pass the most expensive model
  /// the program can select, INCLUDING fallback-chain members; see
  /// [mostExpensiveSelectableModel] for the canonical derivation).
  final String? modelName;

  /// Response allowance per model call, in tokens (the static stand-in for
  /// `maxOutputTokens`).
  final int responseAllowanceTokens;

  const CostAnalyzer({
    required this.pricingCatalog,
    this.modelName,
    this.responseAllowanceTokens = 1024,
    this.estimator = const HeuristicTokenEstimator(),
    this.callOverheadFactor = 1.0,
  });

  (CostBound, List<CheckFinding>) analyze(ControlFlowGraph cfg) {
    final program = cfg.program;
    final instructions = program.instructions;
    final findings = <CheckFinding>[];

    // Per-pc execution multiplier from loop nesting.
    final multiplier = List<int>.filled(instructions.length, 1);
    var sawUnbounded = false;

    for (final (from, head) in cfg.backEdges()) {
      final bound = _tripBound(instructions, head, from);
      if (bound == null) {
        findings.add(UnboundedLoop(headPc: head, pc: from));
        sawUnbounded = true;
        continue;
      }
      // The loop body spans [head, from] in the compiler's layout.
      for (var pc = head; pc <= from && pc < instructions.length; pc++) {
        multiplier[pc] *= bound;
      }
    }

    // Agent tool-loop ceilings, per created agent.
    final agentLoopCeiling = <String, int>{
      for (final op in instructions.whereType<CreateAgentOp>())
        op.descriptor.agentId: op.descriptor.maxToolCallLoops,
    };

    var calls = 0;
    var tokens = 0;
    final reachable = cfg.reachable();
    var unboundedCallSeen = false;
    for (var pc = 0; pc < instructions.length; pc++) {
      if (!reachable.contains(pc)) continue;
      final m = multiplier[pc];
      final inUnbounded =
          sawUnbounded &&
          cfg.backEdges().any(
            (e) => _tripBound(instructions, e.$2, e.$1) == null && pc >= e.$2 && pc <= e.$1,
          );
      switch (instructions[pc]) {
        case PromptOp op:
          if (inUnbounded) {
            unboundedCallSeen = true;
          }
          calls += m;
          tokens += m * (estimator.forText(op.promptText) + responseAllowanceTokens);
        case DecideOp op:
          if (inUnbounded) unboundedCallSeen = true;
          calls += m;
          tokens += m * (estimator.forText(op.prompt) + responseAllowanceTokens);
        case DispatchAgentTaskOp op:
          if (inUnbounded) unboundedCallSeen = true;
          final turns = agentLoopCeiling[op.agentId] ?? 10;
          calls += m * turns;
          tokens += m * turns * (estimator.forText(op.taskPrompt) + responseAllowanceTokens);
        case DispatchParallelTasksOp op:
          if (inUnbounded) unboundedCallSeen = true;
          for (final d in op.dispatches) {
            final turns = agentLoopCeiling[d.agentId] ?? 10;
            calls += m * turns;
            tokens += m * turns * (estimator.forText(d.taskPrompt) + responseAllowanceTokens);
          }
        default:
          break;
      }
    }

    // Harness overhead scales the whole call, prompt and response alike
    // (the prove-it measurement was of total wire usage vs the bound).
    final adjustedTokens = (tokens * callOverheadFactor).ceil();

    double? cost;
    final name = modelName;
    if (name != null && !unboundedCallSeen) {
      cost = pricingCatalog.resolveCostUsd(
        UsageMetadata(
          promptTokenCount: ((tokens - calls * responseAllowanceTokens) * callOverheadFactor).ceil(),
          candidatesTokenCount: (calls * responseAllowanceTokens * callOverheadFactor).ceil(),
          source: UsageSource.estimated,
        ),
        name,
      );
    }

    return (
      CostBound(
        maxModelCalls: calls,
        maxTokens: adjustedTokens,
        maxCostUsd: cost,
        unbounded: unboundedCallSeen,
      ),
      findings,
    );
  }

  /// Recognizes the compiler's canonical bounded-loop guard: inside
  /// [head, from] a `CompareRegisterOp(leftVar: c, operator: 'lt',
  /// rightValue: const N)` whose counter `c` is zero-initialized before the
  /// loop and incremented within it. Returns N, or null when unrecognized.
  int? _tripBound(List<VasterInstruction> instructions, int head, int from) {
    for (var pc = head; pc <= from && pc < instructions.length; pc++) {
      final instruction = instructions[pc];
      if (instruction is! CompareRegisterOp) continue;
      if (instruction.operator != 'lt') continue;
      final bound = instruction.rightValue;
      if (bound is! int || bound < 0) continue;
      final counter = instruction.leftVar;

      final zeroInit = instructions
          .take(head)
          .whereType<SetRegisterOp>()
          .any((op) => op.registerName == counter && op.value == 0);
      final incremented = instructions
          .getRange(head, from + 1 > instructions.length ? instructions.length : from + 1)
          .whereType<IncrementRegisterOp>()
          .any((op) => op.registerName == counter);
      if (zeroInit && incremented) return bound;
    }
    return null;
  }
}
