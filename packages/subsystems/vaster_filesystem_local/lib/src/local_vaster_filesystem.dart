import 'dart:io';
import 'dart:typed_data';

import 'package:vaster_filesystem/vaster_filesystem.dart';

/// Host disk implementation of [VasterFileSystem] scoped within a [rootPath] directory.
class LocalVasterFileSystem implements VasterFileSystem {
  final Directory rootDirectory;
  final String? mountPrefix;

  LocalVasterFileSystem(String rootPath, {this.mountPrefix}) : rootDirectory = Directory(rootPath).absolute;

  String _cleanRelPath(String virtualPath) {
    var rel = virtualPath.replaceAll('\\', '/');
    if (mountPrefix != null && rel.startsWith(mountPrefix!)) {
      rel = rel.substring(mountPrefix!.length);
    } else if (rel.startsWith('/workspace')) {
      rel = rel.substring('/workspace'.length);
    }
    if (rel.startsWith('/')) rel = rel.substring(1);
    return rel;
  }

  File _resolveFile(String virtualPath) {
    final rel = _cleanRelPath(virtualPath);
    return File('${rootDirectory.path}/$rel');
  }

  Directory _resolveDir(String virtualPath) {
    final rel = _cleanRelPath(virtualPath);
    return Directory('${rootDirectory.path}/$rel');
  }

  @override
  Future<String> readText(String path) async {
    final file = _resolveFile(path);
    return await file.readAsString();
  }

  @override
  Future<String> writeText(String path, String content) async {
    final file = _resolveFile(path);
    await file.parent.create(recursive: true);
    await file.writeAsString(content);
    return file.path;
  }

  @override
  Future<Uint8List> readBytes(String path) async {
    final file = _resolveFile(path);
    return await file.readAsBytes();
  }

  @override
  Future<String> writeBytes(String path, Uint8List bytes) async {
    final file = _resolveFile(path);
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes);
    return file.path;
  }

  @override
  Future<FileDescriptor?> getDescriptor(String path) async {
    final file = _resolveFile(path);
    if (!await file.exists()) return null;

    final stat = await file.stat();
    final normPath = path.startsWith('/') ? path : '/$path';
    return FileDescriptor(path: normPath, sizeBytes: stat.size, modifiedTimestamp: stat.modified);
  }

  @override
  Future<bool> exists(String path) async {
    final file = _resolveFile(path);
    if (await file.exists()) return true;
    final dir = _resolveDir(path);
    return await dir.exists();
  }

  @override
  Future<bool> delete(String path, {bool recursive = false}) async {
    final file = _resolveFile(path);
    if (await file.exists()) {
      await file.delete();
      return true;
    }
    final dir = _resolveDir(path);
    if (await dir.exists()) {
      await dir.delete(recursive: recursive);
      return true;
    }
    return false;
  }

  @override
  Future<List<VirtualNode>> listDirectory(String path, {bool recursive = false}) async {
    final dir = _resolveDir(path);
    if (!await dir.exists()) return [];

    final nodes = <VirtualNode>[];
    await for (final entity in dir.list(recursive: recursive)) {
      final virtPath = '/${entity.path.substring(rootDirectory.path.length + 1)}';
      final name = entity.path.split(Platform.pathSeparator).last;

      if (entity is File) {
        final stat = await entity.stat();
        nodes.add(
          VirtualFile(
            path: virtPath,
            name: name,
            descriptor: FileDescriptor(
              path: virtPath,
              sizeBytes: stat.size,
              modifiedTimestamp: stat.modified,
            ),
            bytes: await entity.readAsBytes(),
          ),
        );
      } else if (entity is Directory) {
        nodes.add(VirtualDirectory(path: virtPath, name: name));
      }
    }

    return nodes;
  }

  @override
  Future<FileSystemSnapshot> createSnapshot() async {
    final snapshotFiles = <String, Uint8List>{};
    if (await rootDirectory.exists()) {
      await for (final entity in rootDirectory.list(recursive: true)) {
        if (entity is File) {
          final virtPath = '/${entity.path.substring(rootDirectory.path.length + 1)}';
          snapshotFiles[virtPath] = await entity.readAsBytes();
        }
      }
    }
    return FileSystemSnapshot(files: snapshotFiles);
  }

  @override
  Future<int> restoreSnapshot(FileSystemSnapshot snapshot) async {
    if (await rootDirectory.exists()) {
      await rootDirectory.delete(recursive: true);
    }
    await rootDirectory.create(recursive: true);

    for (final entry in snapshot.files.entries) {
      final file = _resolveFile(entry.key);
      await file.parent.create(recursive: true);
      await file.writeAsBytes(entry.value);
    }
    return snapshot.files.length;
  }

  /// Disk-backed content survives the process by nature — the checkpoint
  /// carries this mount's PATH, not its bytes (Rule 8's descriptors-are-
  /// state discipline). Exporting gigabytes of workspace into a JSON
  /// checkpoint would be the wrong durability model.
  @override
  Map<String, String> exportFilesBase64() => const {};

  @override
  int importFilesBase64(Map<String, String> files) => 0;
}
