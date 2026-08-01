/// Descriptor handle metadata defining an agent's identity, role, and capabilities.
class AgentDescriptor {
  /// Unique agent identifier.
  final String agentId;

  /// Human-readable name (e.g. 'ResearchAgent', 'CoderAgent').
  final String name;

  /// High-level role or job title description.
  final String role;

  /// Top-level system prompt instruction guiding agent behavior.
  final String systemInstruction;

  /// Whitelist of allowed tool names accessible by this agent.
  final List<String> allowedToolNames;

  /// Arbitrary metadata attributes.
  final Map<String, dynamic> metadata;

  const AgentDescriptor({
    required this.agentId,
    required this.name,
    required this.role,
    required this.systemInstruction,
    this.allowedToolNames = const [],
    this.metadata = const {},
  });

  Map<String, dynamic> toJson() => {
        'agentId': agentId,
        'name': name,
        'role': role,
        'systemInstruction': systemInstruction,
        'allowedToolNames': allowedToolNames,
        if (metadata.isNotEmpty) 'metadata': metadata,
      };

  factory AgentDescriptor.fromJson(Map<String, dynamic> json) {
    return AgentDescriptor(
      agentId: json['agentId'] as String? ?? '',
      name: json['name'] as String? ?? '',
      role: json['role'] as String? ?? '',
      systemInstruction: json['systemInstruction'] as String? ?? '',
      allowedToolNames:
          (json['allowedToolNames'] as List?)?.cast<String>() ?? [],
      metadata: Map<String, dynamic>.from(json['metadata'] as Map? ?? {}),
    );
  }

  @override
  String toString() =>
      'AgentDescriptor(id: "$agentId", name: "$name", role: "$role")';
}
