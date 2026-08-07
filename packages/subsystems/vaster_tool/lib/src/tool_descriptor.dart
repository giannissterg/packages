import 'package:vaster_model/vaster_model.dart';

/// Lightweight handle descriptor defining a tool's identity and parameters schema.
class ToolDescriptor {
  /// Unique tool name (e.g. 'read_file', 'search_web').
  final String name;

  /// Human/LLM readable description of tool function and usage guidance.
  final String description;

  /// JSON Schema definition of parameters accepted by this tool.
  final Map<String, dynamic> parametersSchema;

  const ToolDescriptor({
    required this.name,
    required this.description,
    this.parametersSchema = const {'type': 'object', 'properties': {}},
  });

  /// Converts this descriptor to a [ToolDefinition] for inclusion in a [ModelRequest].
  ToolDefinition toDefinition() {
    return ToolDefinition(name: name, description: description, parametersSchema: parametersSchema);
  }

  Map<String, dynamic> toJson() => {
    'name': name,
    'description': description,
    'parametersSchema': parametersSchema,
  };

  factory ToolDescriptor.fromJson(Map<String, dynamic> json) {
    return ToolDescriptor(
      name: json['name'] as String? ?? '',
      description: json['description'] as String? ?? '',
      parametersSchema: Map<String, dynamic>.from(json['parametersSchema'] as Map? ?? <String, dynamic>{}),
    );
  }

  @override
  String toString() => 'ToolDescriptor(name: "$name")';
}
