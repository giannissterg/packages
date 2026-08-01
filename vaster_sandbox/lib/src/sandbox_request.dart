import 'sandbox_security_policy.dart';

/// Execution request payload sent to a [CodeSandbox].
class SandboxRequest {
  /// Code snippet or command line string to execute.
  final String codeOrCommand;

  /// Target language / runtime ('dart', 'bash', 'python').
  final String language;

  /// Input arguments / variable bindings passed into execution scope.
  final Map<String, dynamic> inputs;

  /// Environment variables.
  final Map<String, String> environment;

  /// Custom security policy for this request, overriding default sandbox policy.
  final SandboxSecurityPolicy? securityPolicy;

  const SandboxRequest({
    required this.codeOrCommand,
    this.language = 'dart',
    this.inputs = const {},
    this.environment = const {},
    this.securityPolicy,
  });

  Map<String, dynamic> toJson() => {
        'codeOrCommand': codeOrCommand,
        'language': language,
        if (inputs.isNotEmpty) 'inputs': inputs,
        if (environment.isNotEmpty) 'environment': environment,
        if (securityPolicy != null) 'securityPolicy': securityPolicy!.toJson(),
      };

  factory SandboxRequest.fromJson(Map<String, dynamic> json) {
    return SandboxRequest(
      codeOrCommand: json['codeOrCommand'] as String? ?? '',
      language: json['language'] as String? ?? 'dart',
      inputs: Map<String, dynamic>.from(json['inputs'] as Map? ?? {}),
      environment: Map<String, String>.from(json['environment'] as Map? ?? {}),
      securityPolicy: json['securityPolicy'] != null
          ? SandboxSecurityPolicy.fromJson(json['securityPolicy'] as Map<String, dynamic>)
          : null,
    );
  }

  @override
  String toString() =>
      'SandboxRequest(lang: $language, codeLength: ${codeOrCommand.length})';
}
