import 'package:test/test.dart';
import 'package:vaster_model/vaster_model.dart';
import 'package:vaster_model_fake/vaster_model_fake.dart';
import 'package:vaster_session/vaster_session.dart';

void main() {
  group('ModelSession Forking', () {
    test('forks session creating deep copy of message history', () async {
      final fakeModel = FakeVasterModel();
      final originalSession = BasicModelSession(
        sessionId: 'main_session',
        model: fakeModel,
      );

      await originalSession.send(ChatMessage.user('Turn 1'));
      expect(originalSession.history, hasLength(2)); // user + model echo

      final forkedSession = originalSession.fork(newSessionId: 'branch_session');
      expect(forkedSession.sessionId, equals('branch_session'));
      expect(forkedSession.history, hasLength(2));

      // Mutate forked session
      await forkedSession.send(ChatMessage.user('Fork Turn 2'));
      expect(forkedSession.history, hasLength(4));

      // Main session history MUST remain unmutated!
      expect(originalSession.history, hasLength(2));
    });
  });
}
