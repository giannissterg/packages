import 'dart:convert';

import 'package:vaster_vm/vaster_vm.dart';

/// Resolves ISA register interpolation (`${name}` / `$$`) against the
/// machine's [RegisterFile].
///
/// See [RegisterInterpolation] in `vaster_instruction` for the normative
/// spec: string register values insert verbatim, non-string values as
/// canonical JSON, present-but-null as the empty string; an unresolvable
/// reference is left verbatim and reported through `onMissing`.
///
/// Single-responsibility collaborator composed by the runtime engine, in the
/// same pattern as `ToolCallOrchestrator` and `DecisionArbiter`.
final class RegisterInterpolator {
  final RegisterFile registers;

  const RegisterInterpolator({required this.registers});

  /// Resolves [template]; every unresolvable reference is left verbatim and
  /// its name reported through [onMissing] (once per occurrence).
  String resolve(String template, {void Function(String name)? onMissing}) {
    if (!RegisterInterpolation.mentions(template)) return template;
    final snapshot = registers.snapshot();
    return template.replaceAllMapped(RegisterInterpolation.token, (match) {
      final name = match.group(1);
      if (name == null) return r'$'; // the `$$` escape
      if (!snapshot.containsKey(name)) {
        onMissing?.call(name);
        return match.group(0)!; // leave the reference verbatim
      }
      final value = snapshot[name];
      return switch (value) {
        null => '',
        String s => s,
        _ => jsonEncode(value),
      };
    });
  }

  /// Deep-resolves the string leaf values of a JSON-shaped map (used for
  /// `SendMessageOp` payloads). Keys are never interpolated.
  Map<String, dynamic> resolveMap(Map<String, dynamic> payload,
      {void Function(String name)? onMissing}) {
    Object? walk(Object? value) => switch (value) {
          String s => resolve(s, onMissing: onMissing),
          Map m => <String, dynamic>{
              for (final entry in m.entries) entry.key.toString(): walk(entry.value),
            },
          List l => [for (final item in l) walk(item)],
          _ => value,
        };
    return walk(payload) as Map<String, dynamic>;
  }
}
