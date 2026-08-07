import 'runtime_event.dart';

/// Interface defining the VM runtime Event Bus.
abstract interface class RuntimeEventBus {
  /// Stream of all runtime events emitted by the VM.
  Stream<RuntimeEvent> get stream;

  /// Returns a filtered stream yielding events of target type [T].
  Stream<T> on<T extends RuntimeEvent>();

  /// Publishes a [RuntimeEvent] to the bus stream and returns its
  /// [RuntimeEvent.eventId] — the correlation handle (Rule 11: publish
  /// is NOT a sanctioned sink; an effect you cannot reference afterward
  /// is the review flag).
  String publish(RuntimeEvent event);

  /// Closes the event bus stream controller; returns true when this call
  /// closed it, false when it was already closed.
  Future<bool> close();
}
