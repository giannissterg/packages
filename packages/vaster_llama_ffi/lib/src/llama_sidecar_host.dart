import 'dart:async';
import 'dart:convert';

import 'package:vaster_mmap/vaster_mmap.dart';

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
      final action = SidecarEnvelope.actionOf(envelope);
      if (action != 'generate') {
        return jsonEncode({'error': 'unsupported action "$action"'});
      }
      // The shared codec rebuilds the request; kvFrames refs arrive as
      // cache hints the model's controller resolves against named frames.
      final response =
          await model.generate(SidecarEnvelope.decodeGenerate(envelope));
      return jsonEncode(response.toJson());
    } on Object catch (e) {
      return jsonEncode({'error': e.toString()});
    }
  }
}
