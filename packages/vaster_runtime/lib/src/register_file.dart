import 'dart:convert';

import 'extract_outcome.dart';

/// The VM's named register bank.
///
/// All data read/write operations during ISA instruction execution go through
/// here. [VasterRuntime] holds one instance and delegates all register I/O
/// to it, keeping the fetch-decode loop free of data manipulation logic.
class RegisterFile {
  final Map<String, dynamic> _data = {};

  /// Reads the value stored in [name], or null if unset.
  dynamic read(String name) => _data[name];

  /// Writes [value] into register [name].
  void write(String name, dynamic value) => _data[name] = value;

  /// Bulk-writes [values] into the register file.
  void writeAll(Map<String, dynamic> values) => _data.addAll(values);

  /// Clears all register state.
  void clear() => _data.clear();

  /// Returns an unmodifiable snapshot of the current register state.
  Map<String, dynamic> snapshot() => Map.unmodifiable(_data);

  /// Restores register state from a [snapshot] (e.g. from a continuation).
  void restore(Map<String, dynamic> snapshot) {
    _data.clear();
    _data.addAll(snapshot);
  }

  /// JSON-extracts [jsonKey] from the value at [sourceVar] into [targetVar].
  ///
  /// Tolerant but never silent: every failure shape is returned as a typed
  /// [ExtractOutcome] for the caller to surface (the engine publishes runtime
  /// warnings). On any non-[ExtractOk] outcome the target register is left
  /// unset — locked-in semantics the stress suite asserts.
  ExtractOutcome jsonExtract({
    required String sourceVar,
    required String jsonKey,
    required String targetVar,
  }) {
    final raw = _data[sourceVar];
    if (raw == null) return ExtractSourceMissing(sourceVar: sourceVar);

    final Object? decoded;
    try {
      decoded = raw is Map ? raw : jsonDecode(raw.toString());
    } on FormatException catch (e) {
      return ExtractParseFailure(sourceVar: sourceVar, detail: e.message);
    }
    if (decoded is! Map) {
      return ExtractParseFailure(
          sourceVar: sourceVar,
          detail: 'value is ${decoded.runtimeType}, not a JSON object');
    }
    if (!decoded.containsKey(jsonKey)) {
      return ExtractKeyMissing(
        sourceVar: sourceVar,
        jsonKey: jsonKey,
        availableKeys: [for (final k in decoded.keys) k.toString()],
      );
    }

    _data[targetVar] = decoded[jsonKey];
    return ExtractOk(decoded[jsonKey]);
  }

  /// Concatenates the string values of [sourceVars] (in order) into [targetVar].
  void concat({
    required String targetVar,
    required List<String> sourceVars,
  }) {
    final buffer = StringBuffer();
    for (final name in sourceVars) {
      final v = _data[name];
      if (v != null) buffer.write(v);
    }
    _data[targetVar] = buffer.toString();
  }
}
