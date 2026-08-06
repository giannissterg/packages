/// Strongly-typed enum representing specific security policy rules that can be violated.
enum SecurityViolationRule {
  /// Executable command not in whitelist.
  allowedCommands,

  /// Execution exceeded maxTimeout.
  maxTimeout,

  /// Network sockets or HTTP access blocked.
  allowNetwork,

  /// File write access blocked.
  allowFileSystemWrite,

  /// Memory quota exceeded.
  maxMemory,

  /// Environment variable not in whitelist.
  environmentWhitelist,

  /// Custom or unclassified security rule violation.
  custom,
}

/// Structured error details and stack trace diagnostics captured upon sandbox failure.
class SandboxErrorDetails {
  /// Exception class name or error label.
  final String exceptionType;

  /// Full stack trace string.
  final String? stackTrace;

  /// Strongly-typed security rule that was violated (if securityViolation == true).
  final SecurityViolationRule? violatedRule;

  const SandboxErrorDetails({
    required this.exceptionType,
    this.stackTrace,
    this.violatedRule,
  });

  Map<String, dynamic> toJson() => {
        'exceptionType': exceptionType,
        if (stackTrace != null) 'stackTrace': stackTrace,
        if (violatedRule != null) 'violatedRule': violatedRule!.name,
      };

  factory SandboxErrorDetails.fromJson(Map<String, dynamic> json) {
    final ruleName = json['violatedRule'] as String?;
    final rule = ruleName != null
        ? SecurityViolationRule.values.firstWhere(
            (r) => r.name == ruleName,
            orElse: () => SecurityViolationRule.custom,
          )
        : null;

    return SandboxErrorDetails(
      exceptionType: json['exceptionType'] as String? ?? 'UnknownError',
      stackTrace: json['stackTrace'] as String?,
      violatedRule: rule,
    );
  }

  @override
  String toString() => 'SandboxErrorDetails(type: $exceptionType, rule: ${violatedRule?.name ?? 'none'})';
}
