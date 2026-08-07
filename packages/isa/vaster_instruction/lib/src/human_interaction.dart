/// Types of human interaction requested by an LLM workflow.
enum HumanInteractionType {
  approval('approval'),
  question('question'),
  input('input'),
  review('review');

  final String name;
  const HumanInteractionType(this.name);

  static HumanInteractionType parse(String value) {
    final lower = value.toLowerCase().trim();
    for (final t in HumanInteractionType.values) {
      if (t.name == lower) return t;
    }
    return HumanInteractionType.question;
  }
}

/// Status of a completed human interaction response.
enum HumanResponseStatus {
  approved('approved'),
  rejected('rejected'),
  answered('answered'),
  timedOut('timed_out');

  final String name;
  const HumanResponseStatus(this.name);

  /// Whether this status is an affirmative outcome — the approve/continue
  /// branch of a workflow. [approved] and [answered] are affirmative;
  /// [rejected] and [timedOut] are not.
  bool get isAffirmative => this == approved || this == answered;

  static HumanResponseStatus parse(String value) {
    final lower = value.toLowerCase().trim();
    for (final s in HumanResponseStatus.values) {
      if (s.name == lower) return s;
    }
    return HumanResponseStatus.answered;
  }
}

/// Serializable request generated when a workflow yields for human interaction.
class HumanInteractionRequest {
  final String requestId;
  final HumanInteractionType type;
  final String prompt;
  final List<String> options;
  final String? outputVar;
  final int? timeoutMs;

  const HumanInteractionRequest({
    required this.requestId,
    required this.type,
    required this.prompt,
    this.options = const [],
    this.outputVar,
    this.timeoutMs,
  });

  Map<String, dynamic> toJson() => {
    'requestId': requestId,
    'type': type.name,
    'prompt': prompt,
    if (options.isNotEmpty) 'options': options,
    if (outputVar != null) 'outputVar': outputVar,
    if (timeoutMs != null) 'timeoutMs': timeoutMs,
  };

  factory HumanInteractionRequest.fromJson(Map<String, dynamic> json) {
    return HumanInteractionRequest(
      requestId: json['requestId'] as String? ?? 'req_001',
      type: HumanInteractionType.parse(json['type'] as String? ?? 'question'),
      prompt: json['prompt'] as String? ?? '',
      options: (json['options'] as List? ?? []).cast<String>(),
      outputVar: json['outputVar'] as String?,
      timeoutMs: json['timeoutMs'] as int?,
    );
  }
}

/// Serializable response provided by a human user or external system.
class HumanInteractionResponse {
  final String requestId;
  final HumanResponseStatus status;
  final String value;
  final Map<String, dynamic> metadata;

  const HumanInteractionResponse({
    required this.requestId,
    required this.status,
    required this.value,
    this.metadata = const {},
  });

  /// Factory helper for creating an approval response.
  factory HumanInteractionResponse.approve({
    required String requestId,
    String comment = 'Approved by user.',
  }) {
    return HumanInteractionResponse(
      requestId: requestId,
      status: HumanResponseStatus.approved,
      value: comment,
    );
  }

  /// Factory helper for creating a rejection response.
  factory HumanInteractionResponse.reject({required String requestId, required String reason}) {
    return HumanInteractionResponse(
      requestId: requestId,
      status: HumanResponseStatus.rejected,
      value: reason,
    );
  }

  /// Factory helper for answering a question or providing input.
  factory HumanInteractionResponse.answer({required String requestId, required String answerText}) {
    return HumanInteractionResponse(
      requestId: requestId,
      status: HumanResponseStatus.answered,
      value: answerText,
    );
  }

  Map<String, dynamic> toJson() => {
    'requestId': requestId,
    'status': status.name,
    'value': value,
    if (metadata.isNotEmpty) 'metadata': metadata,
  };

  factory HumanInteractionResponse.fromJson(Map<String, dynamic> json) {
    return HumanInteractionResponse(
      requestId: json['requestId'] as String? ?? '',
      status: HumanResponseStatus.parse(json['status'] as String? ?? 'answered'),
      value: json['value'] as String? ?? '',
      metadata: Map<String, dynamic>.from(json['metadata'] as Map? ?? {}),
    );
  }
}
