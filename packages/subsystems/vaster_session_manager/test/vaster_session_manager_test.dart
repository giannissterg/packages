import 'package:test/test.dart';
import 'package:vaster_model/vaster_model.dart';
import 'package:vaster_model_fake/vaster_model_fake.dart';
import 'package:vaster_session_manager/vaster_session_manager.dart';

void main() {
  group('BasicSessionManager', () {
    test('creates and retrieves active model sessions', () async {
      final SessionManager manager = BasicSessionManager();
      final model = FakeVasterModel();

      final session1 = await manager.createSession(
        sessionId: 'sess_1',
        model: model,
        metadata: {'user': 'alice'},
      );

      final session2 = await manager.createSession(
        sessionId: 'sess_2',
        model: model,
        metadata: {'user': 'bob'},
      );

      expect(manager.activeSessions, hasLength(2));
      expect(manager.activeSessionDescriptors.map((d) => d.sessionId), containsAll(['sess_1', 'sess_2']));

      expect(manager.getSession('sess_1'), equals(session1));
      expect(manager.getSession('sess_2'), equals(session2));
      expect(manager.getSessionDescriptor('sess_2')?.metadata['user'], equals('bob'));
    });

    test('prevents creating duplicate session IDs', () async {
      final manager = BasicSessionManager();
      final model = FakeVasterModel();

      await manager.createSession(sessionId: 'dup', model: model);

      expect(() async => await manager.createSession(sessionId: 'dup', model: model), throwsStateError);
    });

    test('closes sessions cleanly', () async {
      final manager = BasicSessionManager();
      final model = FakeVasterModel();

      final s1 = await manager.createSession(sessionId: 's1', model: model);
      await s1.send(ChatMessage.user('Hi'));
      expect(s1.history, hasLength(2));

      final closed = await manager.closeSession('s1');
      expect(closed, isTrue);
      expect(manager.getSession('s1'), isNull);
      expect(s1.history, isEmpty);
    });

    test('closeAllSessions clears all active sessions', () async {
      final manager = BasicSessionManager();
      final model = FakeVasterModel();

      await manager.createSession(sessionId: 'a', model: model);
      await manager.createSession(sessionId: 'b', model: model);
      expect(manager.activeSessions, hasLength(2));

      await manager.closeAllSessions();
      expect(manager.activeSessions, isEmpty);
    });
  });
}
