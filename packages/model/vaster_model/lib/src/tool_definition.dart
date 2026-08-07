/// Declarative definition of a tool / function available for the model to invoke.
class ToolDefinition {
  /// Unique tool name (e.g. "read_file", "search_web").
  final String name;

  /// Description explaining what the tool does and when the model should call it.
  final String description;

  /// JSON Schema describing the accepted parameters for this tool.
  final Map<String, dynamic> parametersSchema;

  const ToolDefinition({
    required this.name,
    required this.description,
    this.parametersSchema = const {'type': 'object', 'properties': {}},
  });

  Map<String, dynamic> toJson() => {
    'name': name,
    'description': description,
    'parametersSchema': parametersSchema,
  };

  factory ToolDefinition.fromJson(Map<String, dynamic> json) {
    return ToolDefinition(
      name: json['name'] as String? ?? '',
      description: json['description'] as String? ?? '',
      parametersSchema: Map<String, dynamic>.from(json['parametersSchema'] as Map? ?? <String, dynamic>{}),
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ToolDefinition && runtimeType == other.runtimeType && name == other.name;

  @override
  int get hashCode => name.hashCode;

  @override
  String toString() => 'ToolDefinition(name: $name)';
}
