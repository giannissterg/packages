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

  /// Begins a new snapshot transaction. Transactions NEST: each begin
  /// pushes a frame; [commit]/[rollback] operate on the innermost one.
  Future<void> beginTransaction();

  /// Commits the innermost transaction (discards its rollback snapshot;
  /// enclosing transactions keep theirs).
  Future<void> commit();

  /// Rolls the mounted filesystems back to the innermost transaction's
  /// [beginTransaction] snapshot and closes that frame.
  Future<void> rollback();

  /// Number of currently open transaction frames. The runtime's error
  /// unwinding reads this at handler-push time and rolls back to it when a
  /// failure is caught (REL-P4) — a caught error must not leave an
  /// abandoned transaction's writes behind.
  int get transactionDepth;
}
