import 'package:vaster_model_fake/vaster_model_fake.dart';
import 'package:vaster_model/vaster_model.dart';
import 'package:vaster_session_manager/vaster_session_manager.dart';

void main() async {
  print('=== Vaster Session Manager Example ===');

  final SessionManager manager = BasicSessionManager();
  final model = FakeVasterModel(defaultResponseText: 'Multi-session response');

  final sessionA = await manager.createSession(
    sessionId: 'session_alice',
    model: model,
    metadata: {'user': 'Alice'},
  );

  final sessionB = await manager.createSession(
    sessionId: 'session_bob',
    model: model,
    metadata: {'user': 'Bob'},
  );

  print('Active session count: ${manager.activeSessions.length}');
  print('Active session IDs: ${manager.activeSessionDescriptors.map((d) => d.sessionId).join(', ')}');

  await sessionA.send(ChatMessage.user('Hi from Alice'));
  await sessionB.send(ChatMessage.user('Hi from Bob'));

  print('Alice turn history count: ${sessionA.history.length}');
  print('Bob turn history count: ${sessionB.history.length}');

  await manager.closeAllSessions();
  print('Active session count after closeAll: ${manager.activeSessions.length}');

  print('Done!');
}
