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

/// Typed prompt/content template: a const list mixing literal text
/// ([String]) and interpolated values ([Binding]).
///
/// ```dart
/// Task(prompt: Template(['Review this plan:\n', plan]), output: review)
/// Prompt(Template.text('Summarize the findings.'))
/// ```
///
/// Templates compile down to the ISA's `${name}` interpolation strings —
/// the runtime is untouched; what changes is that a reference is an object
/// you can navigate and rename, and an unresolvable reference is
/// structurally impossible. Any part that is neither `String` nor `Binding`
/// is a compile error; a raw `${` inside a text part draws a warning
/// (use a `Binding` part — raw interpolation belongs to the primitives
/// tier).
final class Template {
  // Dart const constructors cannot wrap a parameter in a list literal, so
  // the two forms store separately and [parts] unifies them.
  final List<Object>? _parts;
  final String? _text;

  const Template(List<Object> parts)
      : _parts = parts,
        _text = null;

  /// Pure-text template.
  const Template.text(String text)
      : _text = text,
        _parts = null;

  /// The template's parts: `String` literals and `Binding` references.
  List<Object> get parts => _parts ?? [_text!];

  /// Joins to the ISA `${name}` interpolation string. Sugar nodes use this
  /// when feeding primitives/lowering headers; the compiler adds part
  /// validation diagnostics around the same join.
  String lower() => parts
      .map((p) => p is Binding ? '\${${p.name}}' : p.toString())
      .join();

  @override
  String toString() =>
      'Template(${parts.map((p) => p is Binding ? p : "'$p'").join(', ')})';
}
