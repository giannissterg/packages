import 'package:vaster_events/vaster_events.dart';

void main() async {
  print('=== Vaster Event Bus Example ===');

  final RuntimeEventBus bus = BasicEventBus();

  bus.on<ToolCalledEvent>().listen((event) {
    print('Tool Invoked: ${event.toolName} (callId: ${event.callId})');
  });

  bus.on<ModelFinishedEvent>().listen((event) {
    print('Model Completed: ${event.sessionId} in ${event.executionDuration.inMilliseconds}ms');
  });

  bus.publish(
    ToolCalledEvent(
      eventId: 'evt_1',
      callId: 'c_99',
      toolName: 'read_workspace_file',
      arguments: {'path': 'ideas.md'},
    ),
  );

  bus.publish(
    ModelFinishedEvent(
      eventId: 'evt_2',
      sessionId: 'session_demo',
      finishReason: 'stop',
      totalTokens: 120,
      executionDuration: const Duration(milliseconds: 250),
    ),
  );

  await Future.delayed(const Duration(milliseconds: 20));
  await bus.close();
  print('Done!');
}
