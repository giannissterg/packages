import 'dart:async';
import 'agent_message.dart';
import 'messaging_hub_interface.dart';

/// Standard implementation of [AgentMessagingHub].
class BasicAgentMessagingHub implements AgentMessagingHub {
  final Map<String, List<AgentMessage>> _inboxes = {};
  final StreamController<AgentMessage> _controller =
      StreamController<AgentMessage>.broadcast();

  @override
  void sendMessage(AgentMessage message) {
    _inboxes.putIfAbsent(message.recipientAgentId, () => []).add(message);
    if (!_controller.isClosed) {
      _controller.add(message);
    }
  }

  @override
  List<AgentMessage> getInbox(String agentId) {
    return List.unmodifiable(_inboxes[agentId] ?? const []);
  }

  @override
  Stream<AgentMessage> getMessageStream(String agentId) {
    return _controller.stream.where((msg) => msg.recipientAgentId == agentId);
  }

  @override
  AgentMessage? popNextMessage(String agentId) {
    final inbox = _inboxes[agentId];
    if (inbox == null || inbox.isEmpty) return null;

    final unreadIndex = inbox.indexWhere((m) => !m.isRead);
    if (unreadIndex == -1) return null;

    final msg = inbox[unreadIndex];
    msg.isRead = true;
    return msg;
  }

  @override
  void clearInbox(String agentId) {
    _inboxes.remove(agentId);
  }

  /// Exports every inbox (checkpoint capture) — read/unread state included.
  ///
  /// Undelivered actor messages are durable state: a message sent before a
  /// suspension and popped after resume must survive the process boundary.
  Map<String, List<Map<String, dynamic>>> exportInboxes() => {
        for (final entry in _inboxes.entries)
          entry.key: [for (final m in entry.value) m.toJson()],
      };

  /// Imports inboxes previously exported with [exportInboxes], replacing
  /// same-agent inboxes (checkpoint restore).
  /// Returns the number of messages hydrated across all inboxes — the
  /// checkpoint-restore audit trail (Rule 11).
  int importInboxes(Map<String, List<Map<String, dynamic>>> inboxes) {
    var hydrated = 0;
    for (final entry in inboxes.entries) {
      _inboxes[entry.key] = [
        for (final m in entry.value)
          AgentMessage.fromJson(Map<String, dynamic>.from(m)),
      ];
      hydrated += entry.value.length;
    }
    return hydrated;
  }

  @override
  Future<void> close() async {
    await _controller.close();
  }
}
