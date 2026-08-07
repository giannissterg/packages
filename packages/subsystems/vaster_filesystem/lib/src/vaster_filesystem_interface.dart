import 'dart:typed_data';
import 'file_descriptor.dart';
import 'file_system_snapshot.dart';
import 'virtual_node.dart';

/// Abstract interface class defining a provider-agnostic virtual filesystem.
abstract interface class VasterFileSystem {
  /// Reads text content of file at [path].
  Future<String> readText(String path);

  /// Writes text content to file at [path].
/// Returns the number of BYTES written (Rule 11 receipt).
  Future<int> writeText(String path, String content);

  /// Reads raw bytes of file at [path].
  Future<Uint8List> readBytes(String path);

  /// Writes raw bytes to file at [path].
/// Returns the number of bytes written.
  Future<int> writeBytes(String path, Uint8List bytes);

  /// Returns [FileDescriptor] handle containing file metadata, or null if file doesn't exist.
  Future<FileDescriptor?> getDescriptor(String path);

  /// Checks if a file or directory exists at [path].
  Future<bool> exists(String path);

  /// Deletes file or directory at [path].
  Future<bool> delete(String path, {bool recursive = false});

  /// Lists entries inside directory at [path].
  Future<List<VirtualNode>> listDirectory(String path, {bool recursive = false});

  /// Captures a point-in-time [FileSystemSnapshot] of the filesystem.
  Future<FileSystemSnapshot> createSnapshot();

  /// Restores filesystem state from a [FileSystemSnapshot].
  Future<void> restoreSnapshot(FileSystemSnapshot snapshot);
}
