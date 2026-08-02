import 'dart:convert';
import 'dart:typed_data';

/// Represents a lightweight Copy-on-Write (COW) snapshot of file page references.
///
/// Unmodified files share references to original memory pages (`Uint8List`).
/// Only modified files allocate new byte buffers during transaction execution.
class CowFileSnapshot {
  /// Map of VFS path to immutable page buffer reference.
  final Map<String, Uint8List> pages;

  /// Set of VFS paths modified during the transaction.
  final Set<String> dirtyPaths;

  /// Set of VFS paths deleted during the transaction.
  final Set<String> deletedPaths;

  const CowFileSnapshot({
    required this.pages,
    required this.dirtyPaths,
    required this.deletedPaths,
  });

  /// Creates a shallow copy-on-write snapshot sharing original page buffer references.
  factory CowFileSnapshot.fork(CowFileSnapshot parent) {
    return CowFileSnapshot(
      pages: Map.of(parent.pages),
      dirtyPaths: {},
      deletedPaths: {},
    );
  }

  /// Returns an empty initial snapshot.
  factory CowFileSnapshot.empty() {
    return const CowFileSnapshot(
      pages: {},
      dirtyPaths: {},
      deletedPaths: {},
    );
  }

  /// Serializes the snapshot to JSON, base64-encoding each page buffer.
  Map<String, dynamic> toJson() => {
        'pages': pages.map((path, bytes) => MapEntry(path, base64Encode(bytes))),
        'dirtyPaths': dirtyPaths.toList(),
        'deletedPaths': deletedPaths.toList(),
      };

  /// Reconstructs a snapshot from its [toJson] representation.
  factory CowFileSnapshot.fromJson(Map<String, dynamic> json) {
    final rawPages = (json['pages'] as Map?) ?? const {};
    return CowFileSnapshot(
      pages: rawPages.map(
        (path, encoded) => MapEntry(path as String, base64Decode(encoded as String)),
      ),
      dirtyPaths: ((json['dirtyPaths'] as List?) ?? const [])
          .map((e) => e as String)
          .toSet(),
      deletedPaths: ((json['deletedPaths'] as List?) ?? const [])
          .map((e) => e as String)
          .toSet(),
    );
  }
}

/// Tracks nested Copy-on-Write transaction state in the virtual filesystem manager.
class CowTransactionState {
  final int transactionId;
  final CowFileSnapshot initialSnapshot;
  CowFileSnapshot currentSnapshot;

  CowTransactionState({
    required this.transactionId,
    required this.initialSnapshot,
  }) : currentSnapshot = CowFileSnapshot.fork(initialSnapshot);

  /// Records a Copy-on-Write page write for [vfsPath].
  void recordWrite(String vfsPath, Uint8List bytes) {
    currentSnapshot.pages[vfsPath] = bytes;
    currentSnapshot.dirtyPaths.add(vfsPath);
    currentSnapshot.deletedPaths.remove(vfsPath);
  }

  /// Records a Copy-on-Write file deletion for [vfsPath].
  void recordDelete(String vfsPath) {
    currentSnapshot.pages.remove(vfsPath);
    currentSnapshot.deletedPaths.add(vfsPath);
    currentSnapshot.dirtyPaths.remove(vfsPath);
  }
}
