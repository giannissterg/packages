import 'package:vaster_instruction/vaster_instruction.dart';

/// A symbolic jump target in the compiler's intermediate representation.
///
/// Labels decouple control-flow emission from instruction addresses: passes
/// may insert or delete instructions freely, and concrete PCs are computed
/// only at assembly time. This makes nested control flow correct by
/// construction (single-pass absolute-PC arithmetic breaks for `When` inside
/// `When`).
final class IrLabel {
  final int id;
  final String name;
  const IrLabel(this.id, this.name);

  @override
  String toString() => 'L$id($name)';
}

/// One element of the IR stream: a concrete instruction, a symbolic jump,
/// or a label binding (which occupies no space in the final program).
sealed class IrItem {
  const IrItem();
}

/// A concrete, position-independent instruction.
final class IrInstruction extends IrItem {
  final VasterInstruction instruction;
  const IrInstruction(this.instruction);
}

/// Unconditional jump to a symbolic label (assembles to [JumpOp]).
final class IrJump extends IrItem {
  final IrLabel target;
  const IrJump(this.target);
}

/// Conditional jump to a symbolic label (assembles to [JumpIfOp]).
final class IrJumpIf extends IrItem {
  final String conditionVar;
  final IrLabel target;
  const IrJumpIf(this.conditionVar, this.target);
}

/// Binds [label] to the position of the next emitted instruction.
final class IrBindLabel extends IrItem {
  final IrLabel label;
  const IrBindLabel(this.label);
}

/// A growable IR stream with label allocation and two-pass assembly.
class IrModule {
  final List<IrItem> items = [];
  int _labelCounter = 0;

  /// Allocates a fresh, unbound label.
  IrLabel newLabel(String name) => IrLabel(_labelCounter++, name);

  void emit(VasterInstruction instruction) => items.add(IrInstruction(instruction));

  void jump(IrLabel target) => items.add(IrJump(target));

  void jumpIf(String conditionVar, IrLabel target) =>
      items.add(IrJumpIf(conditionVar, target));

  void bind(IrLabel label) => items.add(IrBindLabel(label));

  /// Assembles the IR into a flat instruction list (classic two-pass layout):
  /// pass 1 assigns each label its PC, pass 2 materializes symbolic jumps.
  ///
  /// Throws [StateError] on a jump to a label that was never bound.
  List<VasterInstruction> assemble() {
    // Pass 1: label -> PC.
    final labelPcs = <int, int>{};
    var pc = 0;
    for (final item in items) {
      switch (item) {
        case IrBindLabel(:final label):
          labelPcs[label.id] = pc;
        case IrInstruction() || IrJump() || IrJumpIf():
          pc++;
      }
    }

    int resolve(IrLabel label) {
      final target = labelPcs[label.id];
      if (target == null) {
        throw StateError('Unbound label $label referenced by a jump.');
      }
      return target;
    }

    // Pass 2: materialize.
    final out = <VasterInstruction>[];
    for (final item in items) {
      switch (item) {
        case IrInstruction(:final instruction):
          out.add(instruction);
        case IrJump(:final target):
          out.add(JumpOp(targetPc: resolve(target)));
        case IrJumpIf(:final conditionVar, :final target):
          out.add(JumpIfOp(conditionVar: conditionVar, targetPc: resolve(target)));
        case IrBindLabel():
          break;
      }
    }
    return out;
  }
}
