import 'dart:typed_data';
import 'file_descriptor.dart';
import 'file_system_snapshot.dart';
import 'virtual_node.dart';

/// Abstract interface class defining a provider-agnostic virtual filesystem.
abstract interface class VasterFileSystem {
  /// Reads text content of file at [path].
  Future<String> readText(String path);

  /// Writes text content to file at [path]; returns the normalized path
  /// the bytes landed on — the receipt a caller can read back, resolve,
  /// or log (Rule 11: never a re-derivation of the caller's own input).
  Future<String> writeText(String path, String content);

  /// Reads raw bytes of file at [path].
  Future<Uint8List> readBytes(String path);

  /// Writes raw bytes to file at [path]; returns the normalized path.
  Future<String> writeBytes(String path, Uint8List bytes);

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

  /// Restores filesystem state from a [FileSystemSnapshot]; returns how
  /// many files were restored.
  Future<int> restoreSnapshot(FileSystemSnapshot snapshot);

  /// Exports this filesystem's contents as pure JSON (path → base64).
  ///
  /// Durability is a CONTRACT obligation (Rule 8) — `vaster_checkpoint`
  /// composes this instead of downcasting to a concrete filesystem,
  /// which silently checkpointed any other implementation as empty.
  /// Backends whose content lives outside the process (disk mounts)
  /// return an empty map: their files survive by nature, and the MOUNT
  /// TABLE is what the checkpoint carries for them.
  Map<String, String> exportFilesBase64();

  /// Imports files previously exported with [exportFilesBase64],
  /// replacing same-path entries; returns how many files were restored.
  int importFilesBase64(Map<String, String> files);
}
