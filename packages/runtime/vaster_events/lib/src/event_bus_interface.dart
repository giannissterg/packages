import 'runtime_event.dart';

/// Interface defining the VM runtime Event Bus.
abstract interface class RuntimeEventBus {
  /// Stream of all runtime events emitted by the VM.
  Stream<RuntimeEvent> get stream;

  /// Returns a filtered stream yielding events of target type [T].
  Stream<T> on<T extends RuntimeEvent>();

  /// Publishes a [RuntimeEvent] and returns its [RuntimeEvent.eventId] —
  /// the correlation handle (Rule 11: publish is NOT a sanctioned sink).
  ///
  /// **Null when nothing was published** (a closed bus drops the event):
  /// a handle for an event that never reached a subscriber could not be
  /// correlated, asserted on, or cancelled, so returning one would be the
  /// fabricated-value anti-pattern. Matches `close()`'s
  /// observable-idempotence precedent.
  String? publish(RuntimeEvent event);

  /// Closes the event bus stream controller; returns true when this call
  /// closed it, false when it was already closed.
  Future<bool> close();
}
