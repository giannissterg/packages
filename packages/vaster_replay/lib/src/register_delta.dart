import 'execution_step_frame.dart';

/// The kind of change a register underwent between two execution step frames.
enum RegisterChangeKind {
  /// The register did not exist before and was introduced.
  added,

  /// The register existed before and no longer exists.
  removed,

  /// The register existed in both frames but its value changed.
  modified,
}

/// A single register-level change between two [ExecutionStepFrame]s.
class RegisterChange {
  /// Name of the register that changed.
  final String register;

  /// How the register changed.
  final RegisterChangeKind kind;

  /// Value in the earlier frame (null when [kind] is [RegisterChangeKind.added]).
  final Object? previousValue;

  /// Value in the later frame (null when [kind] is [RegisterChangeKind.removed]).
  final Object? newValue;

  const RegisterChange({
    required this.register,
    required this.kind,
    this.previousValue,
    this.newValue,
  });

  Map<String, dynamic> toJson() => {
        'register': register,
        'kind': kind.name,
        'previousValue': previousValue,
        'newValue': newValue,
      };

  @override
  String toString() {
    switch (kind) {
      case RegisterChangeKind.added:
        return '+ $register = $newValue';
      case RegisterChangeKind.removed:
        return '- $register (was $previousValue)';
      case RegisterChangeKind.modified:
        return '~ $register: $previousValue -> $newValue';
    }
  }
}

/// The set of register changes between two execution step frames.
///
/// This is the core time-travel diff primitive: given two points in the
/// execution journal, it reports exactly which registers were added, removed,
/// or modified — letting a debugger highlight state mutations step by step.
class RegisterDelta {
  /// Journal step index of the earlier ("before") frame.
  final int fromStepIndex;

  /// Journal step index of the later ("after") frame.
  final int toStepIndex;

  /// All register changes, ordered by register name for stable output.
  final List<RegisterChange> changes;

  const RegisterDelta({
    required this.fromStepIndex,
    required this.toStepIndex,
    required this.changes,
  });

  /// Whether no registers changed between the two frames.
  bool get isEmpty => changes.isEmpty;

  /// Whether at least one register changed between the two frames.
  bool get isNotEmpty => changes.isNotEmpty;

  /// Names of every register that changed, in stable order.
  List<String> get changedRegisters =>
      changes.map((c) => c.register).toList(growable: false);

  /// Computes the register delta between two frames.
  ///
  /// Values are compared with `==`. Register order in the result is stable
  /// (alphabetical) so diffs are deterministic across runs.
  factory RegisterDelta.between(
    ExecutionStepFrame before,
    ExecutionStepFrame after,
  ) {
    final beforeRegs = before.registers;
    final afterRegs = after.registers;

    final names = <String>{...beforeRegs.keys, ...afterRegs.keys}.toList()..sort();

    final changes = <RegisterChange>[];
    for (final name in names) {
      final hadBefore = beforeRegs.containsKey(name);
      final hasAfter = afterRegs.containsKey(name);
      final prev = beforeRegs[name];
      final next = afterRegs[name];

      if (hadBefore && !hasAfter) {
        changes.add(RegisterChange(
          register: name,
          kind: RegisterChangeKind.removed,
          previousValue: prev,
        ));
      } else if (!hadBefore && hasAfter) {
        changes.add(RegisterChange(
          register: name,
          kind: RegisterChangeKind.added,
          newValue: next,
        ));
      } else if (prev != next) {
        changes.add(RegisterChange(
          register: name,
          kind: RegisterChangeKind.modified,
          previousValue: prev,
          newValue: next,
        ));
      }
    }

    return RegisterDelta(
      fromStepIndex: before.stepIndex,
      toStepIndex: after.stepIndex,
      changes: changes,
    );
  }

  Map<String, dynamic> toJson() => {
        'fromStepIndex': fromStepIndex,
        'toStepIndex': toStepIndex,
        'changes': changes.map((c) => c.toJson()).toList(),
      };

  @override
  String toString() =>
      'RegisterDelta($fromStepIndex -> $toStepIndex, ${changes.length} change(s))'
      '${changes.isEmpty ? '' : '\n  ${changes.join('\n  ')}'}';
}
