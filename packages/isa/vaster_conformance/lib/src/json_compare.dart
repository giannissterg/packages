/// One divergence between expected and actual JSON values — the unit of a
/// conformance failure report (spec: ISA.md §Conformance procedure).
final class JsonDivergence {
  /// JSON-pointer-style path (`registers.items[2].name`).
  final String fieldPath;

  final Object? expected;
  final Object? actual;

  const JsonDivergence({required this.fieldPath, required this.expected, required this.actual});

  @override
  String toString() => '$fieldPath: expected ${_short(expected)}, got ${_short(actual)}';

  static String _short(Object? v) {
    final s = '$v';
    return s.length <= 80 ? s : '${s.substring(0, 80)}…';
  }
}

/// The normative deep-JSON comparator (ISA.md §Comparison rules):
/// key-order-insensitive objects with exact key sets (`null` value ≠
/// absent key), order-sensitive arrays, exact strings/bools/null, and
/// MATHEMATICAL number equality (`1` == `1.0`; vectors constrain ints to
/// ±2^53 and doubles to exactly-representable values, so no epsilon).
/// Dart-`toString` coercion is explicitly NOT this rule.
final class JsonComparator {
  const JsonComparator();

  /// Returns the FIRST divergence between [expected] and [actual] in a
  /// deterministic order (object keys compared in the expected value's
  /// iteration order), or null when the values are equal.
  JsonDivergence? diff(Object? expected, Object? actual, {String path = ''}) {
    if (expected == null || actual == null) {
      if (expected == null && actual == null) return null;
      return JsonDivergence(fieldPath: path, expected: expected, actual: actual);
    }
    if (expected is num && actual is num) {
      // Dart `==` on num is mathematical across int/double (1 == 1.0).
      return expected == actual ? null : JsonDivergence(fieldPath: path, expected: expected, actual: actual);
    }
    if (expected is String || expected is bool) {
      return expected == actual ? null : JsonDivergence(fieldPath: path, expected: expected, actual: actual);
    }
    if (expected is List) {
      if (actual is! List) return JsonDivergence(fieldPath: path, expected: expected, actual: actual);
      if (expected.length != actual.length) {
        return JsonDivergence(fieldPath: '$path.length', expected: expected.length, actual: actual.length);
      }
      for (var i = 0; i < expected.length; i++) {
        final d = diff(expected[i], actual[i], path: '$path[$i]');
        if (d != null) return d;
      }
      return null;
    }
    if (expected is Map) {
      if (actual is! Map) return JsonDivergence(fieldPath: path, expected: expected, actual: actual);
      for (final key in expected.keys) {
        if (!actual.containsKey(key)) {
          return JsonDivergence(fieldPath: _child(path, '$key'), expected: expected[key], actual: '(absent)');
        }
      }
      for (final key in actual.keys) {
        if (!expected.containsKey(key)) {
          return JsonDivergence(fieldPath: _child(path, '$key'), expected: '(absent)', actual: actual[key]);
        }
      }
      for (final key in expected.keys) {
        final d = diff(expected[key], actual[key], path: _child(path, '$key'));
        if (d != null) return d;
      }
      return null;
    }
    // Non-JSON type reached the comparator — a vector-authoring bug.
    return JsonDivergence(fieldPath: path, expected: expected, actual: actual);
  }

  static String _child(String path, String key) => path.isEmpty ? key : '$path.$key';
}
