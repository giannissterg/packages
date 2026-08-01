import 'package:vaster_context/vaster_context.dart';
import 'package:vaster_context_manager/vaster_context_manager.dart';
import 'package:vaster_model/vaster_model.dart';
import 'package:vaster_model_fake/vaster_model_fake.dart';
import 'package:vaster_session/vaster_session.dart';

void main() async {
  print('=== Vaster Model Session Example ===');

  final model = FakeVasterModel(defaultResponseText: 'Model session active.');
  final contextManager = BasicContextManager(
    sources: [
      MemoryContextSource(
        id: 'sys',
        data: {'system': 'You are operating in session 1.'},
      ),
    ],
  );

  final ModelSession session = BasicModelSession(
    sessionId: 'session_demo',
    model: model,
    contextManager: contextManager,
  );

  print('Session ID: ${session.sessionId}');
  print('Session Descriptor: ${session.descriptor}');

  print('\nSending turn 1...');
  final res1 = await session.send(ChatMessage.user('Hello session!'));
  print('Response 1: ${res1.text}');

  print('\nSending turn 2 (Streaming)...');
  await for (final chunk in session.sendStream(ChatMessage.user('Describe your status.'))) {
    if (chunk.textDelta != null) {
      print('Delta: ${chunk.textDelta}');
    }
  }

  print('\nSession turn history count: ${session.history.length}');
  print('Done!');
}
