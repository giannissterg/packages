import 'sandbox_language.dart';

/// Handle metadata record identifying a registered sandbox environment.
class SandboxDescriptor {
  /// Unique sandbox identifier.
  final String sandboxId;

  /// Sandbox environment type ('isolate', 'process', 'docker', 'wasm').
  final String type;

  /// Human-readable label or description.
  final String description;

  /// Supported programming languages or runtimes.
  final List<SandboxLanguage> supportedLanguages;

  const SandboxDescriptor({
    required this.sandboxId,
    required this.type,
    required this.description,
    this.supportedLanguages = const [SandboxLanguage.dart],
  });

  Map<String, dynamic> toJson() => {
        'sandboxId': sandboxId,
        'type': type,
        'description': description,
        'supportedLanguages': supportedLanguages.map((l) => l.name).toList(),
      };

  factory SandboxDescriptor.fromJson(Map<String, dynamic> json) {
    return SandboxDescriptor(
      sandboxId: json['sandboxId'] as String? ?? '',
      type: json['type'] as String? ?? 'isolate',
      description: json['description'] as String? ?? '',
      supportedLanguages: (json['supportedLanguages'] as List?)
              ?.map((e) => SandboxLanguage.parse(e.toString()))
              .toList() ??
          [SandboxLanguage.dart],
    );
  }

  @override
  String toString() =>
      'SandboxDescriptor(id: "$sandboxId", type: $type, languages: $supportedLanguages)';
}
