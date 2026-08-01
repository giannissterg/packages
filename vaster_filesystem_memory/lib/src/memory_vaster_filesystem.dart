import 'dart:typed_data';

import 'package:vaster_filesystem/vaster_filesystem.dart';

/// In-memory implementation of [VasterFileSystem] for sandboxed testing and fast isolated VFS operations.
class MemoryVasterFileSystem implements VasterFileSystem {
  final Map<String, Uint8List> _storage = {};
  final Map<String, DateTime> _timestamps = {};

  String _normalizePath(String path) {
    var p = path.replaceAll('\\', '/');
    if (!p.startsWith('/')) p = '/$p';
    while (p.contains('//')) {
      p = p.replaceAll('//', '/');
    }
    if (p.length > 1 && p.endsWith('/')) {
      p = p.substring(0, p.length - 1);
    }
    return p;
  }

  @override
  Future<String> readText(String path) async {
    final bytes = await readBytes(path);
    return String.fromCharCodes(bytes);
  }

  @override
  Future<void> writeText(String path, String content) async {
    await writeBytes(path, Uint8List.fromList(content.codeUnits));
  }

  @override
  Future<Uint8List> readBytes(String path) async {
    final norm = _normalizePath(path);
    final bytes = _storage[norm];
    if (bytes == null) {
      throw StateError('File not found in MemoryVasterFileSystem: "$path"');
    }
    return Uint8List.fromList(bytes);
  }

  @override
  Future<void> writeBytes(String path, Uint8List bytes) async {
    final norm = _normalizePath(path);
    _storage[norm] = Uint8List.fromList(bytes);
    _timestamps[norm] = DateTime.now();
  }

  @override
  Future<FileDescriptor?> getDescriptor(String path) async {
    final norm = _normalizePath(path);
    final bytes = _storage[norm];
    if (bytes == null) return null;

    final mimeType = norm.endsWith('.json')
        ? 'application/json'
        : norm.endsWith('.md')
            ? 'text/markdown'
            : norm.endsWith('.dart')
                ? 'application/dart'
                : 'text/plain';

    return FileDescriptor(
      path: norm,
      sizeBytes: bytes.length,
      mimeType: mimeType,
      modifiedTimestamp: _timestamps[norm] ?? DateTime.now(),
    );
  }

  @override
  Future<bool> exists(String path) async {
    final norm = _normalizePath(path);
    return _storage.containsKey(norm);
  }

  @override
  Future<bool> delete(String path, {bool recursive = false}) async {
    final norm = _normalizePath(path);
    if (_storage.containsKey(norm)) {
      _storage.remove(norm);
      _timestamps.remove(norm);
      return true;
    }
    if (recursive) {
      final prefix = '$norm/';
      final keysToRemove = _storage.keys.where((k) => k.startsWith(prefix)).toList();
      for (final k in keysToRemove) {
        _storage.remove(k);
        _timestamps.remove(k);
      }
      return keysToRemove.isNotEmpty;
    }
    return false;
  }

  @override
  Future<List<VirtualNode>> listDirectory(String path, {bool recursive = false}) async {
    final norm = _normalizePath(path);
    final prefix = norm == '/' ? '/' : '$norm/';

    final nodes = <VirtualNode>[];
    final seenDirectories = <String>{};

    for (final fileKey in _storage.keys) {
      if (fileKey.startsWith(prefix)) {
        final relative = fileKey.substring(prefix.length);
        if (relative.isEmpty) continue;

        final parts = relative.split('/');
        if (parts.length == 1 || recursive) {
          final desc = await getDescriptor(fileKey);
          if (desc != null) {
            nodes.add(VirtualFile(
              path: fileKey,
              name: parts.last,
              descriptor: desc,
              bytes: _storage[fileKey]!,
            ));
          }
        } else if (parts.length > 1) {
          final dirName = parts.first;
          final dirPath = '$prefix$dirName';
          if (!seenDirectories.contains(dirPath)) {
            seenDirectories.add(dirPath);
            nodes.add(VirtualDirectory(
              path: dirPath,
              name: dirName,
            ));
          }
        }
      }
    }

    return nodes;
  }

  @override
  Future<FileSystemSnapshot> createSnapshot() async {
    final snapshotFiles = <String, Uint8List>{};
    for (final entry in _storage.entries) {
      snapshotFiles[entry.key] = Uint8List.fromList(entry.value);
    }
    return FileSystemSnapshot(files: snapshotFiles);
  }

  @override
  Future<void> restoreSnapshot(FileSystemSnapshot snapshot) async {
    _storage.clear();
    _timestamps.clear();
    final now = DateTime.now();
    for (final entry in snapshot.files.entries) {
      _storage[entry.key] = Uint8List.fromList(entry.value);
      _timestamps[entry.key] = now;
    }
  }
}
