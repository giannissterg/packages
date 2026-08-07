import 'agent_message.dart';

/// Interface defining inter-agent message routing and inbox queues.
abstract interface class AgentMessagingHub {
  /// Sends an [AgentMessage] to target recipient's inbox.
  void sendMessage(AgentMessage message);

  /// Returns unmodifiable inbox view for [agentId].
  List<AgentMessage> getInbox(String agentId);

  /// Returns a stream yielding messages sent to [agentId].
  Stream<AgentMessage> getMessageStream(String agentId);

  /// Pops the oldest unread [AgentMessage] for [agentId] and marks it read.
  AgentMessage? popNextMessage(String agentId);

  /// Clears inbox for [agentId].
/// Returns the number of messages dropped (Rule 11 — an empty clear is
  /// observable).
  int clearInbox(String agentId);

  /// Closes messaging hub resources.
/// Returns true when this call closed the hub, false when it was
  /// already closed (idempotence made observable).
  Future<bool> close();
}
