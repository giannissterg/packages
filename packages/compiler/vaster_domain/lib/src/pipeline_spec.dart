/// Top-level workflow pipeline configuration.
class PipelineSpec {
  final String name;
  final String version;
  final String? defaultModelId;
  final String rootStoragePath;
  final Map<String, String> metadata;

  const PipelineSpec({
    required this.name,
    this.version = '1.0.0',
    this.defaultModelId,
    this.rootStoragePath = '/mem',
    this.metadata = const {},
  });

  Map<String, dynamic> toJson() => {
    'name': name,
    'version': version,
    if (defaultModelId != null) 'defaultModelId': defaultModelId,
    'rootStoragePath': rootStoragePath,
    'metadata': metadata,
  };

  factory PipelineSpec.fromJson(Map<String, dynamic> json) {
    return PipelineSpec(
      name: json['name'] as String? ?? 'pipeline',
      version: json['version'] as String? ?? '1.0.0',
      defaultModelId: json['defaultModelId'] as String?,
      rootStoragePath: json['rootStoragePath'] as String? ?? '/mem',
      metadata: Map<String, String>.from(json['metadata'] as Map? ?? {}),
    );
  }

  @override
  String toString() => 'PipelineSpec("$name" v$version)';
}
