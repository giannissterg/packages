import 'dart:convert';
import 'dart:io';

import 'package:vaster_continuation/vaster_continuation.dart';
import 'continuation_store_interface.dart';

/// Durable disk-backed implementation of [ContinuationStore] persisting
/// [VasterContinuation] snapshots as formatted JSON files (`<continuationId>.json`).
class FileContinuationStore implements ContinuationStore {
  final Directory storageDirectory;

  FileContinuationStore({required this.storageDirectory});

  /// Convenience constructor accepting a path string.
  factory FileContinuationStore.fromPath(String path) {
    return FileContinuationStore(storageDirectory: Directory(path));
  }

  Future<Directory> _ensureDirectory() async {
    if (!await storageDirectory.exists()) {
      await storageDirectory.create(recursive: true);
    }
    return storageDirectory;
  }

  File _fileForId(Directory dir, String continuationId) {
    final filename = continuationId.endsWith('.json')
        ? continuationId
        : '$continuationId.json';
    return File('${dir.path}/$filename');
  }

  @override
  Future<String> saveContinuation(VasterContinuation continuation) async {
    final dir = await _ensureDirectory();
    final file = _fileForId(dir, continuation.continuationId);
    final jsonString = const JsonEncoder.withIndent('  ').convert(continuation.toJson());
    await file.writeAsString(jsonString, flush: true);
    return continuation.continuationId;
  }

  @override
  Future<VasterContinuation?> loadContinuation(String continuationId) async {
    final dir = await _ensureDirectory();
    final file = _fileForId(dir, continuationId);
    if (!await file.exists()) return null;
    try {
      final content = await file.readAsString();
      final Map<String, dynamic> json = jsonDecode(content) as Map<String, dynamic>;
      return VasterContinuation.fromJson(json);
    } catch (_) {
      return null;
    }
  }

  @override
  Future<List<VasterContinuation>> listContinuations() async {
    final dir = await _ensureDirectory();
    final continuations = <VasterContinuation>[];
    await for (final entity in dir.list()) {
      if (entity is File && entity.path.endsWith('.json')) {
        try {
          final content = await entity.readAsString();
          final Map<String, dynamic> json = jsonDecode(content) as Map<String, dynamic>;
          continuations.add(VasterContinuation.fromJson(json));
        } catch (_) {}
      }
    }
    return List.unmodifiable(continuations);
  }

  @override
  Future<bool> deleteContinuation(String continuationId) async {
    final dir = await _ensureDirectory();
    final file = _fileForId(dir, continuationId);
    if (await file.exists()) {
      await file.delete();
      return true;
    }
    return false;
  }

  @override
  Future<int> clear() async {
    final dir = await _ensureDirectory();
    var dropped = 0;
    await for (final entity in dir.list()) {
      if (entity is File && entity.path.endsWith('.json')) {
        await entity.delete();
        dropped++;
      }
    }
    return dropped;
  }
}
