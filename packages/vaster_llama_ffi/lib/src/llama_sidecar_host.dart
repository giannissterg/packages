import 'dart:async';
import 'dart:convert';

import 'package:vaster_mmap/vaster_mmap.dart';
import 'package:vaster_model/vaster_model.dart';

import 'llama_ffi_vaster_model.dart';

/// The sidecar side of the zero-copy transport: serves `generate`
/// envelopes from a request ring, answering on a response ring.
///
/// Topology (`vaster serve --backend llama`): this process owns the FFI
/// engine; any number of sequential Vaster processes talk to it through
/// [MmapVasterModel]. The ring carries only small JSON envelopes — bulk
/// context rides as `kvFrames` (named shared-memory frames the engine
/// restores from directly) and generated text rides back in the response
/// envelope.
///
/// Errors are typed on the wire: a failed generate answers
/// `{"error": …}`, which the client surfaces as `SidecarRemoteException`
/// — the transport never fabricates success in either direction.
final class LlamaSidecarHost {
  final LlamaFfiVasterModel model;
  final SharedMemoryRing requestRing;
  final SharedMemoryRing responseRing;
  final Duration pollInterval;

  bool _stopping = false;
  bool _running = false;

  LlamaSidecarHost({
    required this.model,
    required this.requestRing,
    required this.responseRing,
    this.pollInterval = const Duration(milliseconds: 2),
  });

  /// Serves until [stop] is called. One request at a time — the engine is
  /// a single sequence, and the ring protocol is SPSC by rule.
  Future<void> serve() async {
    if (_running) throw StateError('host is already serving');
    _running = true;
    try {
      while (!_stopping) {
        final payload = requestRing.readString();
        if (payload == null) {
          await Future<void>.delayed(pollInterval);
          continue;
        }
        responseRing.writeString(await _answer(payload));
      }
    } finally {
      _running = false;
    }
  }

  /// Asks the serve loop to exit after the in-flight request (if any).
  void stop() => _stopping = true;

  Future<String> _answer(String payload) async {
    try {
      final envelope = jsonDecode(payload) as Map<String, dynamic>;
      if (envelope['action'] != 'generate') {
        return jsonEncode(
            {'error': 'unsupported action "${envelope['action']}"'});
      }
      final request = _decodeRequest(envelope);
      final response = await model.generate(request);
      return jsonEncode(response.toJson());
    } on Object catch (e) {
      return jsonEncode({'error': e.toString()});
    }
  }

  /// Rebuilds a [ModelRequest] from the wire envelope. `kvFrames` refs
  /// become cache hints — the model's controller re-resolves them by
  /// fingerprint and restores state from the named frames' pages.
  static ModelRequest _decodeRequest(Map<String, dynamic> envelope) {
    final system = envelope['systemInstruction'] as String?;
    final frames = (envelope['kvFrames'] as List? ?? const [])
        .cast<Map<String, dynamic>>()
        .map(KvFrameRef.fromJson)
        .toList();
    return ModelRequest(
      systemInstruction:
          system == null || system.isEmpty ? null : ChatMessage.system(system),
      messages: (envelope['messages'] as List? ?? const [])
          .cast<Map<String, dynamic>>()
          .map(ChatMessage.fromJson)
          .toList(),
      cacheHints: [
        for (final ref in frames)
          ContextCacheHint(
              regionId: ref.frameName,
              contentFingerprint: ref.contentFingerprint),
      ],
    );
  }
}
