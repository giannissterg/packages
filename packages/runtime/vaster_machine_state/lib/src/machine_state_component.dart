/// One state-bearing component of the machine.
///
/// Implemented BY composition — components implement this interface; nothing
/// inherits a base class. The runtime enumerates its components in exactly
/// one registration list, so capture is a fold and forgetting a component
/// requires deleting a line, not failing to add one.
///
/// Snapshots are pure JSON (Rule 1: descriptors and handles, never live
/// objects) and must round-trip: `restoreState(captureState())` on a fresh
/// component reproduces the original's behavior exactly.
abstract interface class MachineStateComponent {
  /// Stable key naming this component inside a [MachineSnapshot]
  /// (e.g. `registers`, `callStack`, `machineContext`).
  String get stateKey;

  /// This component's complete state as pure JSON.
  Map<String, dynamic> captureState();

  /// Replaces this component's state with a previously captured snapshot.
  void restoreState(Map<String, dynamic> snapshot);
}
