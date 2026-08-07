import 'package:vaster_continuation/vaster_continuation.dart';

/// Abstract interface contract defining persistence operations for [VasterContinuation] snapshots.
abstract interface class ContinuationStore {
  /// Saves or overwrites a [VasterContinuation] snapshot in persistent storage.
/// Returns the saved continuation's id — the handle [loadContinuation]
  /// retrieves it by (Rule 11).
  Future<String> saveContinuation(VasterContinuation continuation);

  /// Retrieves a stored [VasterContinuation] snapshot by [continuationId], or null if not found.
  Future<VasterContinuation?> loadContinuation(String continuationId);

  /// Returns an unmodifiable list of all stored [VasterContinuation] snapshots.
  Future<List<VasterContinuation>> listContinuations();

  /// Deletes a stored [VasterContinuation] snapshot by [continuationId].
  /// Returns `true` if snapshot existed and was deleted, `false` otherwise.
  Future<bool> deleteContinuation(String continuationId);

  /// Clears all stored continuation snapshots.
  Future<void> clear();
}
