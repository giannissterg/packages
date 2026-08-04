/// Feature capabilities and resource boundaries of a specific model backend.
class ModelCapabilities {
  /// Maximum context token capacity (input + output).
  final int maxContextTokens;

  /// Maximum output token limit for a single request candidate.
  final int maxOutputTokens;

  /// Whether the model backend supports streaming output chunks.
  final bool supportsStreaming;

  /// Whether the model backend supports tool / function calls.
  final bool supportsFunctionCalling;

  /// Whether the model backend supports multimodal input (images/audio/video).
  final bool supportsVision;

  /// Whether the model backend supports system instructions.
  final bool supportsSystemInstruction;

  /// Whether the model backend supports internal reasoning / thoughts.
  final bool supportsReasoning;

  /// Whether the backend wire-reports exact monetary cost on
  /// `UsageMetadata.costUsd` (e.g. the claude CLI's `total_cost_usd`). A
  /// capability of the interface, not pricing data — rate tables live in
  /// `vaster_pricing`.
  final bool reportsCostUsd;

  const ModelCapabilities({
    this.maxContextTokens = 128000,
    this.maxOutputTokens = 8192,
    this.supportsStreaming = true,
    this.supportsFunctionCalling = true,
    this.supportsVision = true,
    this.supportsSystemInstruction = true,
    this.supportsReasoning = false,
    this.reportsCostUsd = false,
  });

  Map<String, dynamic> toJson() => {
        'maxContextTokens': maxContextTokens,
        'maxOutputTokens': maxOutputTokens,
        'supportsStreaming': supportsStreaming,
        'supportsFunctionCalling': supportsFunctionCalling,
        'supportsVision': supportsVision,
        'supportsSystemInstruction': supportsSystemInstruction,
        'supportsReasoning': supportsReasoning,
        if (reportsCostUsd) 'reportsCostUsd': reportsCostUsd,
      };

  factory ModelCapabilities.fromJson(Map<String, dynamic> json) {
    return ModelCapabilities(
      maxContextTokens: json['maxContextTokens'] as int? ?? 128000,
      maxOutputTokens: json['maxOutputTokens'] as int? ?? 8192,
      supportsStreaming: json['supportsStreaming'] as bool? ?? true,
      supportsFunctionCalling:
          json['supportsFunctionCalling'] as bool? ?? true,
      supportsVision: json['supportsVision'] as bool? ?? true,
      supportsSystemInstruction:
          json['supportsSystemInstruction'] as bool? ?? true,
      supportsReasoning: json['supportsReasoning'] as bool? ?? false,
      reportsCostUsd: json['reportsCostUsd'] as bool? ?? false,
    );
  }

  @override
  String toString() =>
      'ModelCapabilities(ctx: $maxContextTokens, out: $maxOutputTokens, tools: $supportsFunctionCalling, vision: $supportsVision)';
}
