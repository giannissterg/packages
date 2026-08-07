import 'package:test/test.dart';
import 'package:vaster_context/vaster_context.dart';
import 'package:vaster_context_manager/vaster_context_manager.dart';
import 'package:vaster_model/vaster_model.dart';
import 'package:vaster_model_fake/vaster_model_fake.dart';
import 'package:vaster_session/vaster_session.dart';

void main() {
  group('BasicModelSession', () {
    test('sends user message and appends model response to history', () async {
      final fakeModel = FakeVasterModel(defaultResponseText: 'Session response');
      final ModelSession session = BasicModelSession(
        sessionId: 'sess_1',
        model: fakeModel,
        contextManager: BasicContextManager(),
      );

      expect(session.sessionId, equals('sess_1'));
      expect(session.history, isEmpty);

      final response = await session.send(ChatMessage.user('Hello session'));
      expect(response.text, contains('Session response'));
      expect(session.history.length, equals(2));
      expect(session.history.first.text, equals('Hello session'));
      expect(session.history.last.text, contains('Session response'));
    });

    test('supports dynamic model switching per turn', () async {
      final defaultModel = FakeVasterModel(modelName: 'fast-model', defaultResponseText: 'Fast model output');
      final targetModel = FakeVasterModel(
        modelName: 'reasoning-model',
        defaultResponseText: 'Reasoning model output',
      );

      final session = BasicModelSession(
        sessionId: 'sess_dyn',
        model: defaultModel,
        contextManager: BasicContextManager(),
      );

      final res1 = await session.send(ChatMessage.user('Turn 1'));
      expect(res1.text, contains('Fast model output'));
      expect(defaultModel.recordedRequests, hasLength(1));
      expect(targetModel.recordedRequests, isEmpty);

      final res2 = await session.send(ChatMessage.user('Turn 2'), targetModel: targetModel);
      expect(res2.text, contains('Reasoning model output'));
      expect(targetModel.recordedRequests, hasLength(1));
    });

    test('sendStream streams chunks and updates history', () async {
      final fakeModel = FakeVasterModel(defaultResponseText: 'Stream response');
      final session = BasicModelSession(
        sessionId: 'sess_stream',
        model: fakeModel,
        contextManager: BasicContextManager(),
      );

      final chunks = await session.sendStream(ChatMessage.user('Stream test')).toList();
      expect(chunks.isNotEmpty, isTrue);
      expect(session.history.length, equals(2));
      expect(session.history.last.text, contains('Stream'));
      expect(session.history.last.text, contains('response'));
    });

    test('binds with ContextManager and compiles context', () async {
      final fakeModel = FakeVasterModel(defaultResponseText: 'Contextual response');
      final contextManager = BasicContextManager(
        sources: [
          MemoryContextSource.fromMap(id: 'mem', data: {'system': 'You are bound to a session context.'}),
        ],
      );

      final session = BasicModelSession(
        sessionId: 'sess_ctx',
        model: fakeModel,
        contextManager: contextManager,
      );

      final response = await session.send(ChatMessage.user('Query with context'));
      expect(response.text, contains('Contextual response'));

      expect(
        fakeModel.recordedRequests.first.systemInstruction?.text,
        equals('system: You are bound to a session context.'),
      );
    });

    test('clearHistory resets history', () async {
      final fakeModel = FakeVasterModel();
      final session = BasicModelSession(
        sessionId: 's',
        model: fakeModel,
        contextManager: BasicContextManager(),
      );
      await session.send(ChatMessage.user('Hi'));
      expect(session.history, hasLength(2));

      session.clearHistory();
      expect(session.history, isEmpty);
    });
  });
}
