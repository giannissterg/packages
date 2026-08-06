import 'package:vaster_policy/vaster_policy.dart';

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
  /// An empty list means all registered tools are exposed.
  final List<String> allowedToolNames;

  /// Maximum number of model→tool→model loop iterations allowed per task.
  /// Prevents runaway tool call chains. Defaults to 10.
  final int maxToolCallLoops;

  /// Optional execution policy governing capabilities and security restrictions for this agent.
  final ExecutionPolicy? policy;

  /// Arbitrary metadata attributes.
  final Map<String, dynamic> metadata;

  const AgentDescriptor({
    required this.agentId,
    required this.name,
    required this.role,
    required this.systemInstruction,
    this.allowedToolNames = const [],
    this.maxToolCallLoops = 10,
    this.policy,
    this.metadata = const {},
  });

  /// ABI naming convention: the model session provisioned for the agent with
  /// [agentId]. The workflow compiler emits session ops against this name and
  /// the agent manager provisions under it — both must agree, so the rule
  /// lives here in the one leaf package every layer already imports.
  static String sessionIdFor(String agentId) => 'sess_$agentId';

  Map<String, dynamic> toJson() => {
        'agentId': agentId,
        'name': name,
        'role': role,
        'systemInstruction': systemInstruction,
        'allowedToolNames': allowedToolNames,
        'maxToolCallLoops': maxToolCallLoops,
        if (policy != null) 'policy': policy!.toJson(),
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
      maxToolCallLoops: json['maxToolCallLoops'] as int? ?? 10,
      policy: json['policy'] != null
          ? ExecutionPolicy.fromJson(json['policy'] as Map<String, dynamic>)
          : null,
      metadata: Map<String, dynamic>.from(json['metadata'] as Map? ?? {}),
    );
  }

  @override
  String toString() =>
      'AgentDescriptor(id: "$agentId", name: "$name", role: "$role")';
}
