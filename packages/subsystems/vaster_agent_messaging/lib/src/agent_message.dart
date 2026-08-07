/// Asynchronous message record passed between peer agents or supervisor trees.
class AgentMessage {
  /// Unique message identifier.
  final String messageId;

  /// Agent ID of the sender.
  final String senderAgentId;

  /// Agent ID of the target recipient.
  final String recipientAgentId;

  /// Message payload (text or structured map).
  final Map<String, dynamic> payload;

  /// Timestamp when message was sent.
  final DateTime timestamp;

  /// Read status flag.
  bool isRead;

  AgentMessage({
    required this.messageId,
    required this.senderAgentId,
    required this.recipientAgentId,
    required this.payload,
    DateTime? timestamp,
    this.isRead = false,
  }) : timestamp = timestamp ?? DateTime.now();

  Map<String, dynamic> toJson() => {
    'messageId': messageId,
    'senderAgentId': senderAgentId,
    'recipientAgentId': recipientAgentId,
    'payload': payload,
    'timestamp': timestamp.toIso8601String(),
    'isRead': isRead,
  };

  factory AgentMessage.fromJson(Map<String, dynamic> json) {
    return AgentMessage(
      messageId: json['messageId'] as String? ?? '',
      senderAgentId: json['senderAgentId'] as String? ?? '',
      recipientAgentId: json['recipientAgentId'] as String? ?? '',
      payload: Map<String, dynamic>.from(json['payload'] as Map? ?? {}),
      timestamp: DateTime.parse(json['timestamp'] as String),
      isRead: json['isRead'] as bool? ?? false,
    );
  }

  @override
  String toString() => 'AgentMessage(id: "$messageId", from: "$senderAgentId", to: "$recipientAgentId")';
}
