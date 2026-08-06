/// Configuration options passed to an LLM model when requesting generation.
class GenerationConfig {
  /// Controls randomness (0.0 = deterministic, 1.0 = creative).
  final double? temperature;

  /// Top-p (nucleus) sampling threshold.
  final double? topP;

  /// Top-k sampling limit.
  final int? topK;

  /// Maximum tokens allowed in candidate output generation.
  final int? maxOutputTokens;

  /// List of stop sequences that interrupt generation.
  final List<String>? stopSequences;

  /// Expected response MIME type (e.g., 'application/json', 'text/plain').
  final String? responseMimeType;

  /// JSON Schema for structured outputs if enforced by the provider.
  final Map<String, dynamic>? responseSchema;

  const GenerationConfig({
    this.temperature,
    this.topP,
    this.topK,
    this.maxOutputTokens,
    this.stopSequences,
    this.responseMimeType,
    this.responseSchema,
  });

  Map<String, dynamic> toJson() => {
        if (temperature != null) 'temperature': temperature,
        if (topP != null) 'topP': topP,
        if (topK != null) 'topK': topK,
        if (maxOutputTokens != null) 'maxOutputTokens': maxOutputTokens,
        if (stopSequences != null) 'stopSequences': stopSequences,
        if (responseMimeType != null) 'responseMimeType': responseMimeType,
        if (responseSchema != null) 'responseSchema': responseSchema,
      };

  factory GenerationConfig.fromJson(Map<String, dynamic> json) {
    return GenerationConfig(
      temperature: (json['temperature'] as num?)?.toDouble(),
      topP: (json['topP'] as num?)?.toDouble(),
      topK: json['topK'] as int?,
      maxOutputTokens: json['maxOutputTokens'] as int?,
      stopSequences: (json['stopSequences'] as List?)?.cast<String>(),
      responseMimeType: json['responseMimeType'] as String?,
      responseSchema: json['responseSchema'] != null
          ? Map<String, dynamic>.from(json['responseSchema'] as Map)
          : null,
    );
  }

  GenerationConfig copyWith({
    double? temperature,
    double? topP,
    int? topK,
    int? maxOutputTokens,
    List<String>? stopSequences,
    String? responseMimeType,
    Map<String, dynamic>? responseSchema,
  }) {
    return GenerationConfig(
      temperature: temperature ?? this.temperature,
      topP: topP ?? this.topP,
      topK: topK ?? this.topK,
      maxOutputTokens: maxOutputTokens ?? this.maxOutputTokens,
      stopSequences: stopSequences ?? this.stopSequences,
      responseMimeType: responseMimeType ?? this.responseMimeType,
      responseSchema: responseSchema ?? this.responseSchema,
    );
  }
}
