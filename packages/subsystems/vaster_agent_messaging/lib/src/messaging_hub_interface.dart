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

  /// Clears inbox for [agentId]; returns the number of messages dropped
  /// (Rule 11 — an empty clear is observable).
  int clearInbox(String agentId);

  /// Exports every inbox as pure JSON — read/unread state included.
  ///
  /// Durability is a CONTRACT obligation, not an implementation detail
  /// (Rule 8: every stateful VM subsystem exposes export/import in its
  /// own package; `vaster_checkpoint` composes them and must never
  /// downcast to a concrete hub — that silently checkpointed any other
  /// implementation as empty).
  Map<String, List<Map<String, dynamic>>> exportInboxes();

  /// Imports inboxes previously exported with [exportInboxes], replacing
  /// same-agent inboxes; returns how many messages were hydrated.
  int importInboxes(Map<String, List<Map<String, dynamic>>> inboxes);

  /// Closes messaging hub resources; returns true when this call closed
  /// the hub, false when it was already closed (idempotence made
  /// observable).
  Future<bool> close();
}
