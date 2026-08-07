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
  Binding inNamespace(String namespace) => namespace.isEmpty ? this : Binding('${namespace}_$name');

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

  const Template(List<Object> parts) : _parts = parts, _text = null;

  /// Pure-text template.
  const Template.text(String text) : _text = text, _parts = null;

  /// The template's parts: `String` literals and `Binding` references.
  List<Object> get parts => _parts ?? [_text!];

  /// Joins to the ISA `${name}` interpolation string. Sugar nodes use this
  /// when feeding primitives/lowering headers; the compiler adds part
  /// validation diagnostics around the same join.
  String lower() => parts.map((p) => p is Binding ? '\${${p.name}}' : p.toString()).join();

  @override
  String toString() => 'Template(${parts.map((p) => p is Binding ? p : "'$p'").join(', ')})';
}

/// Declarative branch condition for `When` — an expression over bound
/// values, not a register name plus knowledge of the truthiness table.
///
/// ```dart
/// When(condition: Cond.isTrue(approved), then: [...])
/// When(condition: Cond.equals(verdict, 'approve'), then: [...])
/// ```
///
/// Kept deliberately minimal (isTrue/equals/notEquals/not); `and`/`or` are
/// expressible as nested `When`s and can graduate into the DSL when a real
/// pipeline needs them. Conditions lower onto the existing
/// `CompareRegisterOp`/`JumpIfOp` — no new ISA.
sealed class Cond {
  const Cond._();

  /// True when the bound value is truthy (non-empty, non-false, non-zero).
  const factory Cond.isTrue(Binding binding) = CondIsTrue._;

  /// True when the bound value loosely equals [value].
  const factory Cond.equals(Binding binding, Object value) = CondEquals._;

  /// True when the bound value does not loosely equal [value].
  const factory Cond.notEquals(Binding binding, Object value) = CondNotEquals._;

  /// Logical negation — free at compile time (branch targets swap).
  const factory Cond.not(Cond inner) = CondNot._;
}

final class CondIsTrue extends Cond {
  final Binding binding;
  const CondIsTrue._(this.binding) : super._();
}

final class CondEquals extends Cond {
  final Binding binding;
  final Object value;
  const CondEquals._(this.binding, this.value) : super._();
}

final class CondNotEquals extends Cond {
  final Binding binding;
  final Object value;
  const CondNotEquals._(this.binding, this.value) : super._();
}

final class CondNot extends Cond {
  final Cond inner;
  const CondNot._(this.inner) : super._();
}

/// Namespace carrier injected by [BindingScope]; composables mint their
/// *default* bindings through `context.scopedBinding(...)` so explicit
/// [Binding] declarations are the exception (cross-scope wiring), not the
/// rule — the `Theme.of` pattern applied to dataflow.
final class BindingScopeData {
  final String namespace;
  const BindingScopeData(this.namespace);
}

/// Scopes default binding names (and phase artifact conventions) for the
/// wrapped subtree. Nested scopes compose (`outer_inner`).
///
/// ```dart
/// BindingScope(
///   namespace: 'checkout',
///   child: Sequence([
///     Specify(goal: ...),   // binds checkout_spec
///     Plan(),               // reads it from the same scope
///     Review(),             // checkout_review / checkout_review_verdict
///   ]),
/// )
/// ```
class BindingScope extends ComposableNode {
  final String namespace;
  final VasterNode child;

  const BindingScope({required this.namespace, required this.child});

  @override
  VasterNode build(BuildContext context) {
    final parent = context.tryRead<BindingScopeData>();
    final full = parent == null || parent.namespace.isEmpty ? namespace : '${parent.namespace}_$namespace';
    return Provider<BindingScopeData>(value: BindingScopeData(full), children: [child]);
  }
}
