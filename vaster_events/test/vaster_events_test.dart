import 'package:test/test.dart';
import 'package:vaster_events/vaster_events.dart';

void main() {
  group('BasicEventBus & RuntimeEvents', () {
    late RuntimeEventBus bus;

    setUp(() {
      bus = BasicEventBus();
    });

    tearDown(() async {
      await bus.close();
    });

    test('publishes and listens to all events on stream', () async {
      final receivedEvents = <RuntimeEvent>[];
      bus.stream.listen(receivedEvents.add);

      bus.publish(ModelStartedEvent(
        eventId: 'e1',
        sessionId: 'sess_1',
        modelName: 'fake-model',
        promptTokenCount: 50,
      ));

      bus.publish(ToolCalledEvent(
        eventId: 'e2',
        callId: 'call_1',
        toolName: 'read_file',
        arguments: {'path': 'ideas.md'},
      ));

      await Future.delayed(const Duration(milliseconds: 10));
      expect(receivedEvents, hasLength(2));
    });

    test('filters typed events using bus.on<T>()', () async {
      final toolEvents = <ToolCalledEvent>[];
      bus.on<ToolCalledEvent>().listen(toolEvents.add);

      bus.publish(ModelStartedEvent(
        eventId: 'e1',
        sessionId: 'sess_1',
        modelName: 'fake-model',
        promptTokenCount: 50,
      ));

      bus.publish(ToolCalledEvent(
        eventId: 'e2',
        callId: 'c2',
        toolName: 'execute_code',
        arguments: {'code': 'print("hi")'},
      ));

      await Future.delayed(const Duration(milliseconds: 10));
      expect(toolEvents, hasLength(1));
      expect(toolEvents.first.toolName, equals('execute_code'));
    });

    test('sealed pattern matching on RuntimeEvent', () {
      final RuntimeEvent event = FileOperationEvent(
        eventId: 'e3',
        operation: FileOperationType.write,
        path: '/mem/data.json',
        sizeBytes: 120,
      );

      final label = switch (event) {
        FileOperationEvent(operation: final op, path: final p) => '${op.name}: $p',
        _ => 'other',
      };

      expect(label, equals('write: /mem/data.json'));
    });
  });
}
