import 'package:vaster_instruction/vaster_instruction.dart';

import 'compiler_ir.dart';

/// IR-level peephole optimizations. Runs before assembly, so removing items
/// can never corrupt jump targets — labels re-resolve afterwards.
///
///  * **Jump-to-next elimination** — a jump whose target label binds
///    immediately after it is a no-op and is removed.
///  * **Dead-code elimination** — instructions following an unconditional
///    terminator ([HaltOp] or an IR jump) are unreachable until a *referenced*
///    label binds, and are removed.
class PeepholePass {
  const PeepholePass();

  List<IrItem> run(List<IrItem> items) {
    var current = _eliminateDeadCode(items);
    // Jump-to-next elimination can expose more dead code and vice versa;
    // iterate to a fixed point (bounded — each round strictly shrinks).
    while (true) {
      final next = _eliminateDeadCode(_eliminateJumpToNext(current));
      if (next.length == current.length) return next;
      current = next;
    }
  }

  List<IrItem> _eliminateJumpToNext(List<IrItem> items) {
    final out = <IrItem>[];
    for (var i = 0; i < items.length; i++) {
      final item = items[i];
      // IrDecide is deliberately excluded: it is never a no-op even when a
      // branch target binds immediately after (the model call is the point).
      final target = switch (item) {
        IrJump(:final target) => target,
        IrJumpIf(:final target) => target,
        _ => null,
      };
      if (target != null && _bindsImmediatelyAfter(items, i, target)) {
        continue; // no-op jump: fall-through reaches the target anyway
      }
      out.add(item);
    }
    return out;
  }

  bool _bindsImmediatelyAfter(List<IrItem> items, int index, IrLabel target) {
    for (var i = index + 1; i < items.length; i++) {
      final item = items[i];
      if (item is IrBindLabel) {
        if (item.label.id == target.id) return true;
        continue; // other labels occupy no space — keep scanning
      }
      return false; // hit a real instruction before the target bound
    }
    return false;
  }

  List<IrItem> _eliminateDeadCode(List<IrItem> items) {
    final referenced = <int>{};
    for (final item in items) {
      switch (item) {
        case IrJump(:final target):
          referenced.add(target.id);
        case IrJumpIf(:final target):
          referenced.add(target.id);
        case IrCall(:final target):
          referenced.add(target.id);
        case IrPushErrorHandler(:final target):
          referenced.add(target.id);
        case IrDecide(:final branches):
          referenced.addAll([for (final b in branches) b.target.id]);
        case IrInstruction() || IrBindLabel():
          break;
      }
    }

    final out = <IrItem>[];
    var reachable = true;
    for (final item in items) {
      switch (item) {
        case IrBindLabel(:final label):
          if (referenced.contains(label.id)) reachable = true;
          out.add(item); // labels are free — always keep for assembly
        case IrInstruction(:final instruction):
          if (!reachable) continue;
          out.add(item);
          if (instruction is HaltOp) reachable = false;
        case IrJump():
          if (!reachable) continue;
          out.add(item);
          reachable = false;
        case IrDecide():
          // Always transfers control to one of its branch labels — code
          // between a decide and the next referenced label is unreachable.
          if (!reachable) continue;
          out.add(item);
          reachable = false;
        case IrJumpIf() || IrCall() || IrPushErrorHandler():
          if (!reachable) continue;
          out.add(item);
      }
    }
    return out;
  }
}
