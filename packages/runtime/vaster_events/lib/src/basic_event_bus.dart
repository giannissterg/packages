import 'dart:async';
import 'event_bus_interface.dart';
import 'runtime_event.dart';

/// Standard broadcast implementation of [RuntimeEventBus].
class BasicEventBus implements RuntimeEventBus {
  final StreamController<RuntimeEvent> _controller =
      StreamController<RuntimeEvent>.broadcast();

  @override
  Stream<RuntimeEvent> get stream => _controller.stream;

  @override
  Stream<T> on<T extends RuntimeEvent>() {
    return _controller.stream.where((event) => event is T).cast<T>();
  }

  @override
  void publish(RuntimeEvent event) {
    if (!_controller.isClosed) {
      _controller.add(event);
    }
  }

  @override
  Future<void> close() async {
    await _controller.close();
  }
}
