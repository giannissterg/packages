/// Lightweight handle metadata record describing a file in the virtual filesystem.
class FileDescriptor {
  /// Normalized virtual filesystem path (e.g. '/workspace/ideas.md').
  final String path;

  /// Size of the file in bytes.
  final int sizeBytes;

  /// MIME type string (e.g. 'text/plain', 'application/json').
  final String mimeType;

  /// Last modification timestamp.
  final DateTime modifiedTimestamp;

  const FileDescriptor({
    required this.path,
    required this.sizeBytes,
    this.mimeType = 'text/plain',
    required this.modifiedTimestamp,
  });

  Map<String, dynamic> toJson() => {
    'path': path,
    'sizeBytes': sizeBytes,
    'mimeType': mimeType,
    'modifiedTimestamp': modifiedTimestamp.toIso8601String(),
  };

  factory FileDescriptor.fromJson(Map<String, dynamic> json) {
    return FileDescriptor(
      path: json['path'] as String? ?? '',
      sizeBytes: json['sizeBytes'] as int? ?? 0,
      mimeType: json['mimeType'] as String? ?? 'text/plain',
      modifiedTimestamp: json['modifiedTimestamp'] != null
          ? DateTime.parse(json['modifiedTimestamp'] as String)
          : DateTime.now(),
    );
  }

  @override
  String toString() => 'FileDescriptor(path: "$path", size: ${sizeBytes}B, mime: $mimeType)';
}
