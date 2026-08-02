import 'runtime_event.dart';

/// Interface defining the VM runtime Event Bus.
abstract interface class RuntimeEventBus {
  /// Stream of all runtime events emitted by the VM.
  Stream<RuntimeEvent> get stream;

  /// Returns a filtered stream yielding events of target type [T].
  Stream<T> on<T extends RuntimeEvent>();

  /// Publishes a [RuntimeEvent] to the bus stream.
  void publish(RuntimeEvent event);

  /// Closes the event bus stream controller.
  Future<void> close();
}
