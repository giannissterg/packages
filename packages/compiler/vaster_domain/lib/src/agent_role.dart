import 'package:vaster_model/vaster_model.dart' show ModelDescriptor;

/// Describes an agent role identity provisioned into the pipeline.
class AgentRole {
  /// Unique identifier for this role within the pipeline.
  final String roleId;

  /// Human-readable display name; defaults to [roleId] (AST_REVIEW F3 —
  /// a persona is an id plus an instruction; display names are optional).
  final String name;

  /// A short professional title describing the agent's function
  /// (e.g. "Backend Engineer"); defaults to [name].
  final String title;

  /// System instruction grounding the agent's behaviour and expertise.
  final String instruction;

  /// The model this role's agent runs on (GAP-3b); null = VM default.
  final ModelDescriptor? model;

  /// Ordered fallback chain after [model] — a model-kind failure on an
  /// agent turn falls through, each member tried once (mirrors
  /// `SelectModel.fallbacks`).
  final List<ModelDescriptor> modelFallbacks;

  const AgentRole({
    required this.roleId,
    String? name,
    String? title,
    required this.instruction,
    this.model,
    this.modelFallbacks = const [],
  }) : name = name ?? roleId,
       title = title ?? name ?? roleId;

  Map<String, dynamic> toJson() => {
    'roleId': roleId,
    'name': name,
    'title': title,
    'instruction': instruction,
    if (model != null) 'model': model!.toJson(),
    if (modelFallbacks.isNotEmpty) 'modelFallbacks': [for (final f in modelFallbacks) f.toJson()],
  };

  factory AgentRole.fromJson(Map<String, dynamic> json) {
    return AgentRole(
      roleId: json['roleId'] as String? ?? '',
      name: json['name'] as String? ?? '',
      title: json['title'] as String? ?? '',
      instruction: json['instruction'] as String? ?? '',
      model: json['model'] != null
          ? ModelDescriptor.fromJson(Map<String, dynamic>.from(json['model'] as Map))
          : null,
      modelFallbacks: [
        for (final f in json['modelFallbacks'] as List? ?? const [])
          ModelDescriptor.fromJson(Map<String, dynamic>.from(f as Map)),
      ],
    );
  }

  @override
  String toString() => 'AgentRole("$name" [$title])';
}
