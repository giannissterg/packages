/// Describes where pipeline virtual or disk storage is mounted.
enum StorageMountType {
  /// In-memory virtual filesystem (ephemeral).
  memory,

  /// Host disk-backed filesystem (persistent).
  disk,
}

/// Describes a storage mount point used within the pipeline.
class StorageMount {
  /// The VFS path prefix this storage will be accessible from (e.g. '/workspace').
  final String mountPrefix;

  /// The mount type (memory or disk).
  final StorageMountType type;

  /// Optional host disk path (required when [type] is [StorageMountType.disk]).
  final String? diskPath;

  const StorageMount({required this.mountPrefix, this.type = StorageMountType.memory, this.diskPath});

  /// A host-disk mount (AST_REVIEW F6): `StorageMount.disk('/project', dir)`.
  const StorageMount.disk(this.mountPrefix, String this.diskPath) : type = StorageMountType.disk;

  /// An in-memory mount (AST_REVIEW F6): `StorageMount.memory('/scratch')`.
  const StorageMount.memory(this.mountPrefix) : type = StorageMountType.memory, diskPath = null;

  Map<String, dynamic> toJson() => {
    'mountPrefix': mountPrefix,
    'type': type.name,
    if (diskPath != null) 'diskPath': diskPath,
  };

  factory StorageMount.fromJson(Map<String, dynamic> json) {
    return StorageMount(
      mountPrefix: json['mountPrefix'] as String? ?? '/mem',
      type: StorageMountType.values.firstWhere(
        (e) => e.name == (json['type'] as String? ?? 'memory'),
        orElse: () => StorageMountType.memory,
      ),
      diskPath: json['diskPath'] as String?,
    );
  }

  @override
  String toString() => 'StorageMount("$mountPrefix" [${type.name}])';
}
