/// Describes an agent role identity provisioned into the pipeline.
class AgentRole {
  /// Unique identifier for this role within the pipeline.
  final String roleId;

  /// Human-readable display name.
  final String name;

  /// A short professional title describing the agent's function (e.g. "Backend Engineer").
  final String title;

  /// System instruction grounding the agent's behaviour and expertise.
  final String instruction;

  const AgentRole({
    required this.roleId,
    required this.name,
    required this.title,
    required this.instruction,
  });

  Map<String, dynamic> toJson() => {
        'roleId': roleId,
        'name': name,
        'title': title,
        'instruction': instruction,
      };

  factory AgentRole.fromJson(Map<String, dynamic> json) {
    return AgentRole(
      roleId: json['roleId'] as String? ?? '',
      name: json['name'] as String? ?? '',
      title: json['title'] as String? ?? '',
      instruction: json['instruction'] as String? ?? '',
    );
  }

  @override
  String toString() => 'AgentRole("$name" [$title])';
}
