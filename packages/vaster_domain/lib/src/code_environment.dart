import 'package:vaster_sandbox/vaster_sandbox.dart';

/// Describes a code execution sandbox environment available in the pipeline.
class CodeEnvironment {
  /// Unique identifier for this environment.
  final String envId;

  /// The language this environment executes.
  final SandboxLanguage language;

  /// Execution timeout in milliseconds.
  final int timeoutMs;

  const CodeEnvironment({
    required this.envId,
    this.language = SandboxLanguage.dart,
    this.timeoutMs = 10000,
  });

  Map<String, dynamic> toJson() => {
        'envId': envId,
        'language': language.name,
        'timeoutMs': timeoutMs,
      };

  factory CodeEnvironment.fromJson(Map<String, dynamic> json) {
    return CodeEnvironment(
      envId: json['envId'] as String? ?? '',
      language: SandboxLanguage.parse(json['language'] as String? ?? 'dart'),
      timeoutMs: json['timeoutMs'] as int? ?? 10000,
    );
  }

  @override
  String toString() => 'CodeEnvironment("$envId" [${language.name}])';
}
