/// Handle metadata record identifying a registered sandbox environment.
class SandboxDescriptor {
  /// Unique sandbox identifier.
  final String sandboxId;

  /// Sandbox environment type ('isolate', 'process', 'docker', 'wasm').
  final String type;

  /// Human-readable label or description.
  final String description;

  /// Supported programming languages or runtimes ('dart', 'bash', 'python').
  final List<String> supportedLanguages;

  const SandboxDescriptor({
    required this.sandboxId,
    required this.type,
    required this.description,
    this.supportedLanguages = const ['dart'],
  });

  Map<String, dynamic> toJson() => {
        'sandboxId': sandboxId,
        'type': type,
        'description': description,
        'supportedLanguages': supportedLanguages,
      };

  factory SandboxDescriptor.fromJson(Map<String, dynamic> json) {
    return SandboxDescriptor(
      sandboxId: json['sandboxId'] as String? ?? '',
      type: json['type'] as String? ?? 'isolate',
      description: json['description'] as String? ?? '',
      supportedLanguages:
          (json['supportedLanguages'] as List?)?.cast<String>() ?? ['dart'],
    );
  }

  @override
  String toString() =>
      'SandboxDescriptor(id: "$sandboxId", type: $type, languages: $supportedLanguages)';
}
