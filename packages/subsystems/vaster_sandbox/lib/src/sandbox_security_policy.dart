/// Security boundaries and constraints enforced on sandbox execution.
class SandboxSecurityPolicy {
  /// Maximum allowed execution duration.
  final Duration maxTimeout;

  /// Whether outbound network sockets / HTTP calls are allowed.
  final bool allowNetwork;

  /// Whitelist of allowed executable commands (for process sandboxes).
  final List<String>? allowedCommands;

  /// Environment variable key whitelist.
  final List<String> environmentWhitelist;

  const SandboxSecurityPolicy({
    this.maxTimeout = const Duration(seconds: 30),
    this.allowNetwork = false,
    this.allowedCommands,
    this.environmentWhitelist = const ['PATH', 'USER', 'HOME', 'TMPDIR'],
  });

  Map<String, dynamic> toJson() => {
    'maxTimeoutMs': maxTimeout.inMilliseconds,
    'allowNetwork': allowNetwork,
    if (allowedCommands != null) 'allowedCommands': allowedCommands,
    'environmentWhitelist': environmentWhitelist,
  };

  factory SandboxSecurityPolicy.fromJson(Map<String, dynamic> json) {
    return SandboxSecurityPolicy(
      maxTimeout: Duration(milliseconds: json['maxTimeoutMs'] as int? ?? 30000),
      allowNetwork: json['allowNetwork'] as bool? ?? false,
      allowedCommands: (json['allowedCommands'] as List?)?.cast<String>(),
      environmentWhitelist:
          (json['environmentWhitelist'] as List?)?.cast<String>() ?? ['PATH', 'USER', 'HOME', 'TMPDIR'],
    );
  }

  @override
  String toString() => 'SandboxSecurityPolicy(timeout: ${maxTimeout.inSeconds}s, network: $allowNetwork)';
}
