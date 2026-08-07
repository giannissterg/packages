/// Immutable descriptor handle metadata identifying an active or persisted [ModelSession].
class SessionDescriptor {
  /// Unique session identifier.
  final String sessionId;

  /// Identifier or name of the model backend associated with this session.
  final String modelName;

  /// Creation timestamp.
  final DateTime createdTimestamp;

  /// Metadata attributes attached to this session.
  final Map<String, dynamic> metadata;

  SessionDescriptor({
    required this.sessionId,
    required this.modelName,
    DateTime? createdTimestamp,
    this.metadata = const {},
  }) : createdTimestamp = createdTimestamp ?? DateTime.now();

  Map<String, dynamic> toJson() => {
    'sessionId': sessionId,
    'modelName': modelName,
    'createdTimestamp': createdTimestamp.toIso8601String(),
    if (metadata.isNotEmpty) 'metadata': metadata,
  };

  factory SessionDescriptor.fromJson(Map<String, dynamic> json) {
    return SessionDescriptor(
      sessionId: json['sessionId'] as String? ?? '',
      modelName: json['modelName'] as String? ?? '',
      createdTimestamp: json['createdTimestamp'] != null
          ? DateTime.parse(json['createdTimestamp'] as String)
          : DateTime.now(),
      metadata: Map<String, dynamic>.from(json['metadata'] as Map? ?? {}),
    );
  }

  @override
  String toString() => 'SessionDescriptor(id: $sessionId, model: $modelName, created: $createdTimestamp)';
}
