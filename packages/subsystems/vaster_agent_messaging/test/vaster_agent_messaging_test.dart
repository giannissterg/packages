import 'package:test/test.dart';
import 'package:vaster_agent_messaging/vaster_agent_messaging.dart';

void main() {
  group('BasicAgentMessagingHub', () {
    late AgentMessagingHub hub;

    setUp(() {
      hub = BasicAgentMessagingHub();
    });

    tearDown(() async {
      await hub.close();
    });

    test('sends message and updates inbox', () {
      final msg = AgentMessage(
        messageId: 'm1',
        senderAgentId: 'ag_sender',
        recipientAgentId: 'ag_receiver',
        payload: {'status': 'ready'},
      );

      hub.sendMessage(msg);
      final inbox = hub.getInbox('ag_receiver');
      expect(inbox, hasLength(1));
      expect(inbox.first.messageId, equals('m1'));
    });

    test('pops next unread message and marks read', () {
      hub.sendMessage(AgentMessage(
        messageId: 'm1',
        senderAgentId: 's',
        recipientAgentId: 'r',
        payload: {'v': 1},
      ));

      final popped = hub.popNextMessage('r');
      expect(popped?.messageId, equals('m1'));
      expect(popped?.isRead, isTrue);

      final poppedAgain = hub.popNextMessage('r');
      expect(poppedAgain, isNull);
    });

    test('streams messages targeted to recipient', () async {
      final received = <AgentMessage>[];
      hub.getMessageStream('r2').listen(received.add);

      hub.sendMessage(AgentMessage(
        messageId: 'm_other',
        senderAgentId: 's',
        recipientAgentId: 'r1',
        payload: {},
      ));

      hub.sendMessage(AgentMessage(
        messageId: 'm_target',
        senderAgentId: 's',
        recipientAgentId: 'r2',
        payload: {'text': 'hi'},
      ));

      await Future.delayed(const Duration(milliseconds: 10));
      expect(received, hasLength(1));
      expect(received.first.messageId, equals('m_target'));
    });
  });
}
