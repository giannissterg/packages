import 'package:vaster_instruction/vaster_instruction.dart';

import 'check_finding.dart';
import 'control_flow_graph.dart';

/// Definite-assignment analysis: every register read must be dominated by a
/// write on EVERY path from entry — not merely "a write exists somewhere",
/// which is all the flat liveness heuristic could say.
///
/// Forward must-dataflow to fixpoint: `IN[pc] = ∩ OUT[preds]`,
/// `OUT[pc] = IN[pc] ∪ writes(pc)`. Reads include every `${name}` mention in
/// the ISA's normative interpolated fields (see `RegisterInterpolation`).
///
/// Deliberately optimistic where the ISA is tolerant: `JsonExtractOp` counts
/// as a write even though it no-ops on a missing key (the runtime publishes
/// its own typed warning there), and unknown opcodes contribute nothing —
/// the analysis under-warns rather than crying wolf.
final class DefiniteAssignment {
  final ControlFlowGraph cfg;

  const DefiniteAssignment(this.cfg);

  List<CheckFinding> analyze() {
    final program = cfg.program;
    final n = program.instructions.length;
    if (n == 0) return const [];

    final reads = <int, Set<String>>{};
    final writes = <int, Set<String>>{};
    final everWritten = <String>{};
    for (var pc = 0; pc < n; pc++) {
      reads[pc] = _readsOf(program.instructions[pc]);
      writes[pc] = _writesOf(program.instructions[pc]);
      everWritten.addAll(writes[pc]!);
    }

    // Fixpoint over must-defined sets. Unreachable pcs keep `null` (top).
    final preds = cfg.predecessors();
    final reachable = cfg.reachable();
    final inSets = <int, Set<String>?>{for (var pc = 0; pc < n; pc++) pc: null};
    inSets[0] = <String>{};

    var changed = true;
    while (changed) {
      changed = false;
      for (var pc = 0; pc < n; pc++) {
        if (!reachable.contains(pc)) continue;
        Set<String>? merged = pc == 0 ? <String>{} : null;
        for (final pred in preds[pc]!) {
          if (!reachable.contains(pred)) continue;
          final predIn = inSets[pred];
          if (predIn == null) continue; // not yet computed: skip (top)
          final predOut = {...predIn, ...writes[pred]!};
          merged = merged == null ? predOut : merged.intersection(predOut);
        }
        if (merged == null) continue;
        final current = inSets[pc];
        if (current == null || current.length != merged.length || !current.containsAll(merged)) {
          inSets[pc] = merged;
          changed = true;
        }
      }
    }

    final findings = <CheckFinding>[];
    for (var pc = 0; pc < n; pc++) {
      if (!reachable.contains(pc)) continue;
      final definitelySet = inSets[pc] ?? const <String>{};
      for (final register in reads[pc]!) {
        if (definitelySet.contains(register)) continue;
        findings.add(
          everWritten.contains(register)
              ? PossiblyUnsetRead(register: register, pc: pc)
              : ReadNeverWritten(register: register, pc: pc),
        );
      }
    }
    return findings;
  }

  /// Register names mentioned by `${name}` in an interpolated field.
  static Set<String> interpolationReads(String text) => {
    if (RegisterInterpolation.mentions(text))
      for (final m in RegisterInterpolation.token.allMatches(text))
        if (m.group(1) != null) m.group(1)!,
  };

  static Set<String> _readsOf(VasterInstruction instruction) => switch (instruction) {
    PromptOp op => interpolationReads(op.promptText),
    DispatchAgentTaskOp op => interpolationReads(op.taskPrompt),
    DispatchParallelTasksOp op => {for (final d in op.dispatches) ...interpolationReads(d.taskPrompt)},
    WriteFileOp op => {...interpolationReads(op.vfsPath), ...interpolationReads(op.content)},
    ReadFileOp op => interpolationReads(op.vfsPath),
    ExecSandboxOp op => interpolationReads(op.code),
    AddContextOp op => interpolationReads(op.text),
    DecideOp op => interpolationReads(op.prompt),
    YieldHumanInteractionOp op => interpolationReads(op.request.prompt),
    SendMessageOp op => _payloadReads(op.payload),
    JumpIfOp op => {op.conditionVar},
    CompareRegisterOp op => {op.leftVar},
    ConcatRegisterOp op => {...op.sourceVars},
    JsonExtractOp op => {op.sourceVar},
    ReturnSubroutineOp op => {?op.returnRegister},
    IncrementRegisterOp op => {op.registerName},
    _ => const {},
  };

  static Set<String> _payloadReads(Map<String, dynamic> payload) {
    final reads = <String>{};
    void walk(Object? value) {
      switch (value) {
        case String s:
          reads.addAll(interpolationReads(s));
        case Map m:
          m.values.forEach(walk);
        case List l:
          l.forEach(walk);
      }
    }

    walk(payload);
    return reads;
  }

  static Set<String> _writesOf(VasterInstruction instruction) => switch (instruction) {
    SetRegisterOp op => {op.registerName},
    IncrementRegisterOp op => {op.registerName},
    CompareRegisterOp op => {op.targetVar},
    ConcatRegisterOp op => {op.targetVar},
    JsonExtractOp op => {op.targetVar},
    PromptOp op => {?op.outputVar},
    DispatchAgentTaskOp op => {?op.outputVar},
    DispatchParallelTasksOp op => {for (final d in op.dispatches) ?d.outputVar},
    DecideOp op => {?op.outputVar, if (op.outputVar != null) decideRationaleRegister(op.outputVar!)},
    YieldHumanInteractionOp op => {
      ?op.request.outputVar,
      if (op.request.outputVar != null) hitlStatusRegister(op.request.outputVar!),
    },
    ReadFileOp op => {?op.outputVar},
    ExecSandboxOp op => {?op.outputVar},
    PopMessageOp op => {?op.outputVar},
    CompressContextOp op => {?op.outputVar},
    // The subroutine's return write lands on the caller's continuation,
    // which is only reachable through the matched return — attributing
    // it to the call keeps the analysis sound for compiler-shaped
    // programs. Arguments are written before the jump.
    CallOp op => {...op.arguments.keys, ?op.outputVar},
    _ => const {},
  };
}
