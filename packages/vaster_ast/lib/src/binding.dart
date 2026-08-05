part of 'ast_lib.dart';

/// A named dataflow wire between declarative nodes.
///
/// Declared once and referenced at both the producing slot (`output:`) and
/// every consuming slot (`from:`, [Template] parts, [Cond] operands) — so
/// wiring is rename-safe, navigable, and checkable at compile time. A
/// binding compiles away to an ISA register name; it never exists at
/// runtime (Rule 1: bytecode stays language-agnostic).
///
/// ```dart
/// const spec = Binding('spec');
///
/// Task(prompt: Template.text('Write the spec.'), output: spec),
/// Task(prompt: Template(['Review this:\n', spec])),
/// ```
///
/// Bindings are usually *provided by scope* rather than declared inline —
/// composables mint their defaults through `BuildContext` (the `Theme.of`
/// pattern); explicit declarations are for cross-scope wiring.
final class Binding {
  /// Register name this binding compiles to. Names with the reserved `__`
  /// prefix are rejected at compile time.
  final String name;

  const Binding(this.name);

  /// A namespaced child binding: `Binding('spec').inNamespace('checkout')`
  /// → `checkout_spec`.
  Binding inNamespace(String namespace) =>
      namespace.isEmpty ? this : Binding('${namespace}_$name');

  // Identity equality on purpose: overriding == would make Binding illegal
  // as a const map key (Inputs). The NAME is the wire — two bindings with
  // the same name compile to the same register regardless of object
  // identity, and the compiler compares names, never objects.

  @override
  String toString() => 'Binding($name)';
}
