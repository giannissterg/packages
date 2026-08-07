import 'package:vaster_context/vaster_context.dart';
import 'package:vaster_filesystem/vaster_filesystem.dart';

/// Interface for managing virtual filesystem mount points, transactions, and context bridging.
abstract interface class FileSystemManager {
  /// Unmodifiable view of active mount points (prefix -> VasterFileSystem).
  Map<String, VasterFileSystem> get mounts;

  /// Mounts a filesystem backend at [mountPrefix] (e.g. '/mem',
  /// '/workspace') and returns the NORMALIZED prefix it mounted under —
  /// the handle resolution actually uses (Rule 11; callers previously
  /// could not know the normalization).
  String mount(String mountPrefix, VasterFileSystem fileSystem);

  /// Unmounts a filesystem backend by prefix.
  bool unmount(String mountPrefix);

  /// Resolves the target [VasterFileSystem] backend mounted for [path].
  VasterFileSystem resolveFileSystem(String path);

  /// Bridges file content at [path] into a [FileContextSource] for context compilation.
  Future<FileContextSource> toContextSource(String path);

  /// Begins a new snapshot transaction and returns the new
  /// [transactionDepth]. Transactions NEST: each begin pushes a frame;
  /// [commit]/[rollback] operate on the innermost one.
  Future<int> beginTransaction();

  /// Commits the innermost transaction (discards its rollback snapshot;
  /// enclosing transactions keep theirs) and returns the remaining depth.
  Future<int> commit();

  /// Rolls the mounted filesystems back to the innermost transaction's
  /// [beginTransaction] snapshot, closes that frame, and returns the
  /// remaining depth.
  Future<int> rollback();

  /// Number of currently open transaction frames. The runtime's error
  /// unwinding reads this at handler-push time and rolls back to it when a
  /// failure is caught (REL-P4) — a caught error must not leave an
  /// abandoned transaction's writes behind.
  int get transactionDepth;

  /// Serializes the open transaction frames, outermost first — one
  /// `{mountPrefix: {path: base64 content}}` map per frame. Open
  /// transactions are durable machine state (Rule 8): a checkpoint taken
  /// inside a `Transaction` must restore with its rollback protection
  /// intact, not silently commit-by-loss.
  List<Map<String, Map<String, String>>> exportTransactions();

  /// Restores frames previously exported with [exportTransactions],
  /// replacing any currently open frames; returns the restored depth —
  /// the checkpoint-restore audit trail (Rule 11).
  int importTransactions(List<Map<String, Map<String, String>>> frames);
}
