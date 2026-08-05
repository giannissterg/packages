import 'package:vaster_instruction/vaster_instruction.dart';

/// The program's control-flow graph: successor edges per instruction index.
///
/// Edges are conservative where control is dynamic:
/// - [DecideOp] branches to every labeled target (the model picks one).
/// - [CallOp] transfers to its subroutine; every [ReturnSubroutineOp]
///   branches to the continuation of every call site (sound merge for
///   must-analyses — intersection only shrinks).
/// - [YieldHumanInteractionOp] falls through (the resume path).
/// - [HaltOp] (and a [ReturnSubroutineOp] on an empty stack, which halts)
///   has no successors; return edges cover the non-empty-stack case.
final class ControlFlowGraph {
  final VasterProgram program;
  final Map<int, List<int>> successors;

  ControlFlowGraph._(this.program, this.successors);

  factory ControlFlowGraph.of(VasterProgram program) {
    final instructions = program.instructions;
    final callContinuations = <int>[
      for (var pc = 0; pc < instructions.length; pc++)
        if (instructions[pc] is CallOp && pc + 1 < instructions.length) pc + 1,
    ];

    List<int> inRange(Iterable<int> targets) => [
          for (final t in targets)
            if (t >= 0 && t < instructions.length) t,
        ];

    final successors = <int, List<int>>{};
    for (var pc = 0; pc < instructions.length; pc++) {
      final next = pc + 1 < instructions.length ? pc + 1 : null;
      successors[pc] = switch (instructions[pc]) {
        JumpOp op => inRange([op.targetPc]),
        JumpIfOp op => inRange([op.targetPc, ?next]),
        DecideOp op => inRange([for (final b in op.branches) b.targetPc]),
        CallOp op => inRange([op.targetPc]),
        ReturnSubroutineOp _ => inRange(callContinuations),
        HaltOp _ => const [],
        _ => inRange([?next]),
      };
    }
    return ControlFlowGraph._(program, successors);
  }

  /// Instruction indices reachable from entry (pc 0).
  Set<int> reachable() {
    final seen = <int>{};
    final work = [if (program.instructions.isNotEmpty) 0];
    while (work.isNotEmpty) {
      final pc = work.removeLast();
      if (!seen.add(pc)) continue;
      work.addAll(successors[pc] ?? const []);
    }
    return seen;
  }

  /// Predecessor map (computed from [successors]).
  Map<int, List<int>> predecessors() {
    final preds = <int, List<int>>{
      for (var pc = 0; pc < program.instructions.length; pc++) pc: [],
    };
    for (final entry in successors.entries) {
      for (final succ in entry.value) {
        preds[succ]!.add(entry.key);
      }
    }
    return preds;
  }

  /// Back-edges: (fromPc → headPc) where the jump target does not lie
  /// strictly forward — the compiler emits all loops this way.
  ///
  /// Call/return structure is NOT iteration: [CallOp] and
  /// [ReturnSubroutineOp] edges are excluded even when they point backward
  /// (a subroutine defined before its call site, a return to an earlier
  /// continuation). Recursion is out of scope for the static bound — the
  /// runtime's supervisor-tree depth limit guards it.
  List<(int from, int head)> backEdges() => [
        for (final entry in successors.entries)
          if (program.instructions[entry.key] is! CallOp &&
              program.instructions[entry.key] is! ReturnSubroutineOp)
            for (final succ in entry.value)
              if (succ <= entry.key) (entry.key, succ),
      ];
}
