/// Type-safe, serializable descriptor uniquely identifying an LLM backend model provider and model variant.
class ModelDescriptor {
  /// Provider identifier (e.g. `gemini_cli`, `google_ai`, `fake`, `openai`).
  final String provider;

  /// Specific model identifier (e.g. `gemini-2.5-flash`, `gemini-1.5-pro`, `gpt-4o`).
  final String modelId;

  /// Optional parameters associated with this model descriptor (e.g. temperature, region).
  final Map<String, String> parameters;

  const ModelDescriptor({
    required this.provider,
    required this.modelId,
    this.parameters = const {},
  });

  /// Factory helper for creating a fake model descriptor.
  const factory ModelDescriptor.fake({String modelId}) = _FakeModelDescriptor;

  /// Factory helper for creating a Gemini CLI model descriptor.
  const factory ModelDescriptor.geminiCli({String modelId}) = _GeminiCliModelDescriptor;

  /// Factory helper for creating a Google AI REST API model descriptor.
  const factory ModelDescriptor.googleAi({String modelId}) = _GoogleAiModelDescriptor;

  /// Unique key used for lookup in [ModelRegistry] (e.g. `gemini_cli:gemini-2.5-flash`).
  String get descriptorKey => '$provider:$modelId';

  Map<String, dynamic> toJson() => {
        'provider': provider,
        'modelId': modelId,
        if (parameters.isNotEmpty) 'parameters': parameters,
      };

  factory ModelDescriptor.fromJson(Map<String, dynamic> json) {
    return ModelDescriptor(
      provider: json['provider'] as String? ?? 'unknown',
      modelId: json['modelId'] as String? ?? 'default',
      parameters: Map<String, String>.from(json['parameters'] as Map? ?? {}),
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ModelDescriptor &&
          runtimeType == other.runtimeType &&
          provider == other.provider &&
          modelId == other.modelId;

  @override
  int get hashCode => provider.hashCode ^ modelId.hashCode;

  @override
  String toString() => 'ModelDescriptor($descriptorKey)';
}

class _FakeModelDescriptor extends ModelDescriptor {
  const _FakeModelDescriptor({super.modelId = 'default'})
      : super(provider: 'fake');
}

class _GeminiCliModelDescriptor extends ModelDescriptor {
  const _GeminiCliModelDescriptor({super.modelId = 'gemini-2.5-flash'})
      : super(provider: 'gemini_cli');
}

class _GoogleAiModelDescriptor extends ModelDescriptor {
  const _GoogleAiModelDescriptor({super.modelId = 'gemini-2.5-flash'})
      : super(provider: 'google_ai');
}
