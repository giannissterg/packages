import 'package:vaster_context/vaster_context.dart';
import 'package:vaster_filesystem/vaster_filesystem.dart';
import 'filesystem_manager_interface.dart';

/// Standard implementation of [FileSystemManager].
class BasicFileSystemManager implements FileSystemManager {
  final Map<String, VasterFileSystem> _mounts = {};
  final Map<String, FileSystemSnapshot> _transactionSnapshots = {};

  BasicFileSystemManager({Map<String, VasterFileSystem>? mounts}) {
    if (mounts != null) {
      for (final entry in mounts.entries) {
        mount(entry.key, entry.value);
      }
    }
  }

  String _normalizePrefix(String prefix) {
    var p = prefix.replaceAll('\\', '/');
    if (!p.startsWith('/')) p = '/$p';
    while (p.endsWith('/') && p.length > 1) {
      p = p.substring(0, p.length - 1);
    }
    return p;
  }

  @override
  Map<String, VasterFileSystem> get mounts => Map.unmodifiable(_mounts);

  @override
  void mount(String mountPrefix, VasterFileSystem fileSystem) {
    final norm = _normalizePrefix(mountPrefix);
    _mounts[norm] = fileSystem;
  }

  @override
  bool unmount(String mountPrefix) {
    final norm = _normalizePrefix(mountPrefix);
    return _mounts.remove(norm) != null;
  }

  @override
  VasterFileSystem resolveFileSystem(String path) {
    final norm = _normalizePrefix(path);

    // Find longest matching prefix
    String? bestMatch;
    for (final prefix in _mounts.keys) {
      if (norm == prefix || norm.startsWith('$prefix/')) {
        if (bestMatch == null || prefix.length > bestMatch.length) {
          bestMatch = prefix;
        }
      }
    }

    if (bestMatch != null) {
      return _mounts[bestMatch]!;
    }

    // Default fallback if mounted at root '/'
    if (_mounts.containsKey('/')) {
      return _mounts['/']!;
    }

    throw StateError('No filesystem mounted for path: "$path"');
  }

  @override
  Future<FileContextSource> toContextSource(String path) async {
    final fs = resolveFileSystem(path);
    final text = await fs.readText(path);
    return FileContextSource(
      id: 'vfs_$path',
      filePath: path,
      content: text,
    );
  }

  @override
  Future<void> beginTransaction() async {
    _transactionSnapshots.clear();
    for (final entry in _mounts.entries) {
      _transactionSnapshots[entry.key] = await entry.value.createSnapshot();
    }
  }

  @override
  Future<void> commit() async {
    _transactionSnapshots.clear();
  }

  @override
  Future<void> rollback() async {
    for (final entry in _transactionSnapshots.entries) {
      final fs = _mounts[entry.key];
      if (fs != null) {
        await fs.restoreSnapshot(entry.value);
      }
    }
    _transactionSnapshots.clear();
  }
}
