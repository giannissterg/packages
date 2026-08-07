import 'dart:convert';

import 'package:vaster_instruction/vaster_instruction.dart';

import 'register_file.dart';

/// Resolves ISA register interpolation (`${name}` / `$$`) against the
/// machine's [RegisterFile].
///
/// See [RegisterInterpolation] in `vaster_instruction` for the normative
/// spec: string register values insert verbatim, non-string values as
/// canonical JSON, present-but-null as the empty string; an unresolvable
/// reference is left verbatim and returned in the result's `missing` list.
///
/// Single-responsibility collaborator composed by the runtime engine, in the
/// same pattern as `ToolCallOrchestrator` and `DecisionArbiter`.
final class RegisterInterpolator {
  final RegisterFile registers;

  const RegisterInterpolator({required this.registers});

  /// Resolves [template] and returns the resolved text together with the
  /// names left UNRESOLVED (verbatim references) — the outcome is data,
  /// not an out-parameter callback (Rule 5/11). Missing names appear in
  /// order, once per occurrence.
  InterpolationResult resolve(String template) {
    if (!RegisterInterpolation.mentions(template)) {
      return InterpolationResult(text: template, missing: const []);
    }
    final snapshot = registers.snapshot();
    final missing = <String>[];
    final text = template.replaceAllMapped(RegisterInterpolation.token, (match) {
      final name = match.group(1);
      if (name == null) return r'$'; // the `$$` escape
      if (!snapshot.containsKey(name)) {
        missing.add(name);
        return match.group(0)!; // leave the reference verbatim
      }
      final value = snapshot[name];
      return switch (value) {
        null => '',
        String s => s,
        _ => jsonEncode(value),
      };
    });
    return InterpolationResult(text: text, missing: missing);
  }

  /// Deep-resolves the string leaf values of a JSON-shaped map (used for
  /// `SendMessageOp` payloads). Keys are never interpolated. Returns the
  /// resolved payload with every unresolved name gathered across the tree.
  ({Map<String, dynamic> payload, List<String> missing}) resolveMap(Map<String, dynamic> payload) {
    final missing = <String>[];
    Object? walk(Object? value) => switch (value) {
      String s => () {
        final r = resolve(s);
        missing.addAll(r.missing);
        return r.text;
      }(),
      Map m => <String, dynamic>{for (final entry in m.entries) entry.key.toString(): walk(entry.value)},
      List l => [for (final item in l) walk(item)],
      _ => value,
    };
    final resolved = walk(payload) as Map<String, dynamic>;
    return (payload: resolved, missing: missing);
  }
}

/// The result of interpolating one template: the resolved [text] and the
/// register names that had no binding (left verbatim).
final class InterpolationResult {
  final String text;
  final List<String> missing;
  const InterpolationResult({required this.text, required this.missing});
}
