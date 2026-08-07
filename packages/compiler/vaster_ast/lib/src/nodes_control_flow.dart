part of 'ast_lib.dart';

// ══════════════════════════════════════════════════════════════════════════════
// Control-flow nodes — loops, subroutines, and error handling.
// ══════════════════════════════════════════════════════════════════════════════

/// Repeats [children] while the value bound to [condition] is truthy.
///
/// The condition is evaluated before each iteration (a standard while loop).
/// [maxIterations] is a compiled-in runaway guard: when reached, the loop
/// exits normally rather than spinning forever.
final class While extends VasterNode {
  final String condition;
  final List<VasterNode> children;
  final int maxIterations;

  const While({required this.condition, required this.children, this.maxIterations = 100});
}

/// Executes [children] exactly [times] times. When [counter] is set, the
/// zero-based iteration index is bound to that name inside the body.
final class Repeat extends VasterNode {
  final int times;
  final List<VasterNode> children;
  final String? counter;

  const Repeat({required this.times, required this.children, this.counter});
}

/// Executes [tryChildren]; if any instruction inside throws, the error text
/// binds to [error] and control transfers to [catchChildren] instead of
/// trapping the VM. Policy violations are NOT catchable.
final class TryCatch extends VasterNode {
  final List<VasterNode> tryChildren;
  final List<VasterNode> catchChildren;
  final String error;

  const TryCatch({required this.tryChildren, this.catchChildren = const [], this.error = '__error__'});
}

/// Defines a named subroutine. Bodies are emitted after the main program and
/// are only reachable via [CallSubroutine]. The value of the body's last
/// output-producing node becomes the subroutine's return value.
final class DefineSubroutine extends VasterNode {
  final String name;
  final List<VasterNode> children;

  const DefineSubroutine({required this.name, required this.children});
}

/// Calls a [DefineSubroutine] by name. [arguments] are bound by name before
/// the jump; the subroutine's return value binds to [output] (auto-allocated
/// when omitted).
final class CallSubroutine extends VasterNode {
  final String name;
  final Map<String, dynamic> arguments;
  final String? output;

  const CallSubroutine({required this.name, this.arguments = const {}, this.output});
}
