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

/// Subroutine call to a symbolic label (assembles to [CallOp]).
final class IrCall extends IrItem {
  final String functionName;
  final IrLabel target;
  final Map<String, String> arguments;
  final String? outputVar;
  const IrCall(this.functionName, this.target, {this.arguments = const {}, this.outputVar});
}

/// Error-handler installation targeting a symbolic label (assembles to
/// [PushErrorHandlerOp]).
final class IrPushErrorHandler extends IrItem {
  final IrLabel target;
  final String errorVar;
  const IrPushErrorHandler(this.target, {this.errorVar = '__error__'});
}

/// One labeled branch of an [IrDecide], targeting a symbolic label.
final class IrDecideBranch {
  final String label;
  final String description;
  final IrLabel target;
  const IrDecideBranch(this.label, this.description, this.target);
}

/// Model-steered multi-way branch to symbolic labels (assembles to
/// [DecideOp]).
final class IrDecide extends IrItem {
  final String prompt;
  final List<IrDecideBranch> branches;
  final String? outputVar;
  final String? defaultLabel;
  const IrDecide(this.prompt, this.branches, {this.outputVar, this.defaultLabel});
}

/// A growable IR stream with label allocation and two-pass assembly.
class IrModule {
  final List<IrItem> items = [];
  int _labelCounter = 0;

  /// Allocates a fresh, unbound label.
  IrLabel newLabel(String name) => IrLabel(_labelCounter++, name);

  /// Appends [item] and returns its IR index — the handle passes address
  /// stream positions by (Rule 11; concrete PCs exist only at assembly).
  int _append(IrItem item) {
    items.add(item);
    return items.length - 1;
  }

  int emit(VasterInstruction instruction) => _append(IrInstruction(instruction));

  int jump(IrLabel target) => _append(IrJump(target));

  int jumpIf(String conditionVar, IrLabel target) => _append(IrJumpIf(conditionVar, target));

  int call(
    String functionName,
    IrLabel target, {
    Map<String, String> arguments = const {},
    String? outputVar,
  }) => _append(IrCall(functionName, target, arguments: arguments, outputVar: outputVar));

  int pushErrorHandler(IrLabel target, {String errorVar = '__error__'}) =>
      _append(IrPushErrorHandler(target, errorVar: errorVar));

  /// Binds [label] at the current stream position and echoes it, so a
  /// label can be allocated, bound, and captured in one expression:
  /// `final head = ir.bind(ir.newLabel('head'))`.
  IrLabel bind(IrLabel label) {
    items.add(IrBindLabel(label));
    return label;
  }

  int decide(String prompt, List<IrDecideBranch> branches, {String? outputVar, String? defaultLabel}) =>
      _append(IrDecide(prompt, branches, outputVar: outputVar, defaultLabel: defaultLabel));

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
        case IrInstruction() || IrJump() || IrJumpIf() || IrCall() || IrPushErrorHandler() || IrDecide():
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
        case IrCall(:final functionName, :final target, :final arguments, :final outputVar):
          out.add(
            CallOp(
              functionName: functionName,
              targetPc: resolve(target),
              arguments: arguments,
              outputVar: outputVar,
            ),
          );
        case IrPushErrorHandler(:final target, :final errorVar):
          out.add(PushErrorHandlerOp(targetPc: resolve(target), errorVar: errorVar));
        case IrDecide(:final prompt, :final branches, :final outputVar, :final defaultLabel):
          out.add(
            DecideOp(
              prompt: prompt,
              branches: [
                for (final b in branches)
                  DecisionBranch(label: b.label, description: b.description, targetPc: resolve(b.target)),
              ],
              outputVar: outputVar,
              defaultLabel: defaultLabel,
            ),
          );
        case IrBindLabel():
          break;
      }
    }
    return out;
  }
}
