import 'package:vaster_continuation/vaster_continuation.dart';
import 'continuation_store_interface.dart';

/// Lightweight in-memory implementation of [ContinuationStore] backed by a `Map`.
/// Suitable for unit testing and ephemeral runtimes.
class MemoryContinuationStore implements ContinuationStore {
  final Map<String, VasterContinuation> _storage = {};

  @override
  Future<String> saveContinuation(VasterContinuation continuation) async {
    _storage[continuation.continuationId] = continuation;
    return continuation.continuationId;
  }

  @override
  Future<VasterContinuation?> loadContinuation(String continuationId) async {
    return _storage[continuationId];
  }

  @override
  Future<List<VasterContinuation>> listContinuations() async {
    return List.unmodifiable(_storage.values);
  }

  @override
  Future<bool> deleteContinuation(String continuationId) async {
    return _storage.remove(continuationId) != null;
  }

  @override
  Future<void> clear() async {
    _storage.clear();
  }
}
