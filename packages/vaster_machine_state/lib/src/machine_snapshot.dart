import 'machine_state_component.dart';

/// The whole machine at one instruction boundary: the program counter plus
/// every component's state, keyed by [MachineStateComponent.stateKey].
///
/// This is the shared vocabulary between the snapshot's *producer* (the
/// runtime) and its *carriers* (`vaster_continuation`,
/// `vaster_checkpoint`) — carriers stay pure-JSON leaves that never depend
/// on the runtime.
final class MachineSnapshot {
  static const int currentFormatVersion = 1;

  final int formatVersion;
  final int pc;
  final Map<String, Map<String, dynamic>> components;

  const MachineSnapshot({
    this.formatVersion = currentFormatVersion,
    required this.pc,
    required this.components,
  });

  /// Folds [componentList] into a snapshot at [pc] — the one way producers
  /// build snapshots, so every registered component is always included.
  factory MachineSnapshot.capture({
    required int pc,
    required List<MachineStateComponent> componentList,
  }) =>
      MachineSnapshot(
        pc: pc,
        components: {
          for (final component in componentList)
            component.stateKey: component.captureState(),
        },
      );

  /// Restores every component present in this snapshot into [componentList],
  /// dispatching by key. Throws [StateError] when the snapshot carries a key
  /// no component claims — a snapshot from a machine with more components
  /// than this one must fail loudly, never drop state silently.
  void restoreInto(List<MachineStateComponent> componentList) {
    final byKey = {for (final c in componentList) c.stateKey: c};
    for (final entry in components.entries) {
      final component = byKey[entry.key];
      if (component == null) {
        throw StateError(
            'Snapshot carries state for unknown component "${entry.key}" — '
            'refusing to drop it silently.');
      }
      component.restoreState(entry.value);
    }
  }

  Map<String, dynamic> toJson() => {
        'formatVersion': formatVersion,
        'pc': pc,
        'components': components,
      };

  factory MachineSnapshot.fromJson(Map<String, dynamic> json) {
    final version = (json['formatVersion'] as num?)?.toInt() ?? 0;
    if (version != currentFormatVersion) {
      throw FormatException(
          'MachineSnapshot format v$version is not supported by this build '
          '(speaks v$currentFormatVersion).');
    }
    return MachineSnapshot(
      formatVersion: version,
      pc: (json['pc'] as num).toInt(),
      components: {
        for (final entry in (json['components'] as Map? ?? const {}).entries)
          entry.key.toString():
              Map<String, dynamic>.from(entry.value as Map),
      },
    );
  }
}
