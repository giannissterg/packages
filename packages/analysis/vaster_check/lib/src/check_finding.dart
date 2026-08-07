enum CheckSeverity { error, warning, info }

/// One static-verification finding — sealed, each shape carrying exactly the
/// data its diagnostic needs (the framework's sealed-outcome law).
sealed class CheckFinding {
  const CheckFinding();

  CheckSeverity get severity;

  /// Stable machine-readable code (e.g. `read_never_written`).
  String get code;

  /// Instruction index the finding anchors to, when it has one.
  int? get pc => null;

  String get message;

  Map<String, dynamic> toJson() => {
    'severity': severity.name,
    'code': code,
    if (pc != null) 'pc': pc,
    'message': message,
  };
}

/// A register is read but NO instruction in the program ever writes it.
final class ReadNeverWritten extends CheckFinding {
  final String register;
  @override
  final int pc;

  const ReadNeverWritten({required this.register, required this.pc});

  @override
  CheckSeverity get severity => CheckSeverity.error;
  @override
  String get code => 'read_never_written';
  @override
  String get message =>
      'Register "$register" is read at pc $pc but never written anywhere '
      'in the program.';
}

/// A register is read on some path before any write dominates it.
final class PossiblyUnsetRead extends CheckFinding {
  final String register;
  @override
  final int pc;

  const PossiblyUnsetRead({required this.register, required this.pc});

  @override
  CheckSeverity get severity => CheckSeverity.warning;
  @override
  String get code => 'possibly_unset_read';
  @override
  String get message =>
      'Register "$register" may be unset when read at pc $pc — a write '
      'exists but does not dominate every path to this read.';
}

/// A statically-known resource provably violates the declared policy.
final class PolicyViolationProven extends CheckFinding {
  final String action;
  final String resource;
  @override
  final int pc;

  const PolicyViolationProven({required this.action, required this.resource, required this.pc});

  @override
  CheckSeverity get severity => CheckSeverity.error;
  @override
  String get code => 'policy_violation_proven';
  @override
  String get message =>
      'Instruction at pc $pc performs $action on "$resource", which the '
      'declared policy denies — this WILL trap at runtime.';
}

/// A policy-checked resource is interpolated — safety cannot be proven
/// statically (the runtime gate still applies).
final class PolicyUnprovable extends CheckFinding {
  final String action;
  final String resourceTemplate;
  @override
  final int pc;

  const PolicyUnprovable({required this.action, required this.resourceTemplate, required this.pc});

  @override
  CheckSeverity get severity => CheckSeverity.warning;
  @override
  String get code => 'policy_unprovable_dynamic';
  @override
  String get message =>
      'Instruction at pc $pc performs $action on interpolated resource '
      '"$resourceTemplate" — statically unprovable; the runtime policy gate '
      'is the only defense.';
}

/// A loop whose trip count could not be bounded statically — the cost bound
/// is therefore unbounded.
final class UnboundedLoop extends CheckFinding {
  /// The back-edge's target (loop head).
  final int headPc;

  /// The jumping instruction.
  @override
  final int pc;

  const UnboundedLoop({required this.headPc, required this.pc});

  @override
  CheckSeverity get severity => CheckSeverity.warning;
  @override
  String get code => 'unbounded_loop';
  @override
  String get message =>
      'Back-edge at pc $pc → $headPc has no recognizable constant trip '
      'bound; model calls inside it make the cost bound unbounded.';
}

/// An instruction that can never execute (no path from entry reaches it).
final class UnreachableInstruction extends CheckFinding {
  @override
  final int pc;
  final String opcode;

  const UnreachableInstruction({required this.pc, required this.opcode});

  @override
  CheckSeverity get severity => CheckSeverity.info;
  @override
  String get code => 'unreachable_instruction';
  @override
  String get message => 'Instruction at pc $pc ($opcode) is unreachable.';
}
