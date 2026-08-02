import 'dart:convert';

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

  /// JSON-extracts [jsonKey] from the value at [sourceVar] and writes the
  /// result into [targetVar]. Silently no-ops on missing keys or parse errors.
  void jsonExtract({
    required String sourceVar,
    required String jsonKey,
    required String targetVar,
  }) {
    final raw = _data[sourceVar];
    if (raw == null) return;
    try {
      final decoded = raw is Map ? raw : jsonDecode(raw.toString());
      if (decoded is Map && decoded.containsKey(jsonKey)) {
        _data[targetVar] = decoded[jsonKey];
      }
    } catch (_) {}
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
