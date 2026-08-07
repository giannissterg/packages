import 'dart:typed_data';

/// Immutable point-in-time snapshot of virtual filesystem state.
class FileSystemSnapshot {
  /// Map of path to file content bytes at snapshot time.
  final Map<String, Uint8List> files;

  /// Timestamp when snapshot was created.
  final DateTime timestamp;

  FileSystemSnapshot({required Map<String, Uint8List> files, DateTime? timestamp})
    : files = Map.unmodifiable(files),
      timestamp = timestamp ?? DateTime.now();

  @override
  String toString() => 'FileSystemSnapshot(files: ${files.length}, timestamp: $timestamp)';
}
