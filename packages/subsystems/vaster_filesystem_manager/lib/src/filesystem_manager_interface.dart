import 'package:vaster_context/vaster_context.dart';
import 'package:vaster_filesystem/vaster_filesystem.dart';

/// Interface for managing virtual filesystem mount points, transactions, and context bridging.
abstract interface class FileSystemManager {
  /// Unmodifiable view of active mount points (prefix -> VasterFileSystem).
  Map<String, VasterFileSystem> get mounts;

  /// Mounts a filesystem backend at [mountPrefix] (e.g. '/mem', '/workspace').
  void mount(String mountPrefix, VasterFileSystem fileSystem);

  /// Unmounts a filesystem backend by prefix.
  bool unmount(String mountPrefix);

  /// Resolves the target [VasterFileSystem] backend mounted for [path].
  VasterFileSystem resolveFileSystem(String path);

  /// Bridges file content at [path] into a [FileContextSource] for context compilation.
  Future<FileContextSource> toContextSource(String path);

  /// Begins a new snapshot transaction.
  Future<void> beginTransaction();

  /// Commits current transaction (discards rollback snapshot).
  Future<void> commit();

  /// Rolls back mounted filesystems to the snapshot captured at [beginTransaction].
  Future<void> rollback();
}
