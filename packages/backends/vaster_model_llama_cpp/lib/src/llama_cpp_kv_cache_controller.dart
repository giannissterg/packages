import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:vaster_kv/vaster_kv.dart';

/// State-addressed [KvCacheController] over a llama.cpp server's slot API.
///
/// This is *real* physical context: `materialize` prefills the prompt into a
/// slot's KV cache and saves the tensor state to disk
/// (`POST /slots/{id}?action=save`); `restore` loads those bytes back
/// (`action=restore`) so the next generation resumes from the cached state
/// without re-processing the prompt.
///
/// Requires the server to run with `--slot-save-path <dir>`.
class LlamaCppKvCacheController implements KvCacheController {
  final String baseUrl;

  /// Slot used for materialize/restore operations.
  final int slotId;

  /// Injectable HTTP client factory for testing.
  final http.Client Function() _clientFactory;

  /// fingerprint -> handle for state saved through this controller.
  final Map<String, KvCacheHandle> _handles = {};

  LlamaCppKvCacheController({
    this.baseUrl = 'http://127.0.0.1:8080',
    this.slotId = 0,
    http.Client Function()? clientFactory,
  }) : _clientFactory = clientFactory ?? http.Client.new;

  @override
  KvCacheCapabilities get capabilities => const KvCacheCapabilities(
        isStateAddressed: true,
        supportsPersistence: true,
        supportsEviction: true,
      );

  @override
  String get backendId => 'llama_cpp';

  String _filename(String fingerprint) => 'vaster_${fingerprint.substring(0, 24)}.bin';

  @override
  Future<KvCacheHandle?> lookup(String contentFingerprint) async =>
      _handles[contentFingerprint];

  @override
  Future<KvCacheHandle> materialize({
    required String contentFingerprint,
    required String content,
    int? tokenEstimate,
  }) async {
    final existing = _handles[contentFingerprint];
    if (existing != null) return existing;

    final client = _clientFactory();
    try {
      // 1. Prefill: process the prompt into the slot's KV cache without
      //    generating (n_predict: 0), keeping the prompt cached in the slot.
      final prefill = await client.post(
        Uri.parse('$baseUrl/completion'),
        headers: {'content-type': 'application/json'},
        body: jsonEncode({
          'prompt': content,
          'n_predict': 0,
          'id_slot': slotId,
          'cache_prompt': true,
        }),
      );
      if (prefill.statusCode != 200) {
        throw StateError('llama.cpp prefill failed ${prefill.statusCode}: ${prefill.body}');
      }
      final prefillJson = jsonDecode(prefill.body) as Map<String, dynamic>;
      final promptTokens =
          (prefillJson['tokens_evaluated'] as int?) ?? tokenEstimate ?? 0;

      // 2. Save the slot's KV tensor state to disk.
      final filename = _filename(contentFingerprint);
      final save = await client.post(
        Uri.parse('$baseUrl/slots/$slotId?action=save'),
        headers: {'content-type': 'application/json'},
        body: jsonEncode({'filename': filename}),
      );
      if (save.statusCode != 200) {
        throw StateError('llama.cpp slot save failed ${save.statusCode}: ${save.body}');
      }
      final saveJson = jsonDecode(save.body) as Map<String, dynamic>;
      final written = (saveJson['n_written'] as num?)?.toInt();

      final handle = KvCacheHandle(
        handleId: filename,
        contentFingerprint: contentFingerprint,
        tokenCount: promptTokens,
        sizeBytes: written,
        backend: backendId,
      );
      _handles[contentFingerprint] = handle;
      return handle;
    } finally {
      client.close();
    }
  }

  @override
  Future<void> restore(KvCacheHandle handle) async {
    final client = _clientFactory();
    try {
      final response = await client.post(
        Uri.parse('$baseUrl/slots/$slotId?action=restore'),
        headers: {'content-type': 'application/json'},
        body: jsonEncode({'filename': handle.handleId}),
      );
      if (response.statusCode != 200) {
        throw StateError(
            'llama.cpp slot restore failed ${response.statusCode}: ${response.body}');
      }
    } finally {
      client.close();
    }
  }

  @override
  Future<bool> evict(KvCacheHandle handle) async {
    final client = _clientFactory();
    try {
      await client.post(Uri.parse('$baseUrl/slots/$slotId?action=erase'));
      return _handles.remove(handle.contentFingerprint) != null;
    } finally {
      client.close();
    }
  }

  @override
  Future<List<KvCacheHandle>> list() async => _handles.values.toList();
}
