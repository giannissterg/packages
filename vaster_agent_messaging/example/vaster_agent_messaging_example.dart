import 'package:vaster_agent_messaging/vaster_agent_messaging.dart';

void main() async {
  print('=== Vaster Inter-Agent Messaging Example ===');

  final AgentMessagingHub hub = BasicAgentMessagingHub();

  hub.getMessageStream('coder').listen((msg) {
    print('Coder Received Message: ${msg.payload}');
  });

  hub.sendMessage(AgentMessage(
    messageId: 'msg_1',
    senderAgentId: 'architect',
    recipientAgentId: 'coder',
    payload: {'command': 'implement_feature', 'module': 'auth'},
  ));

  await Future.delayed(const Duration(milliseconds: 20));
  await hub.close();
  print('Done!');
}
