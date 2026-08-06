import 'dart:async';
import 'dart:convert';

import 'package:vaster_model/vaster_model.dart';

import 'shared_memory_ring.dart';
import 'sidecar_envelope.dart';

/// The serving side of the shared-memory transport: answers `generate`
/// envelopes from a request ring on a response ring — the ring twin of
/// `VasterModelSidecarServer` (the Unix-socket host), and like it,
/// backend-agnostic: any [VasterModel] can be served.
///
/// The ring carries only small JSON envelopes. When the envelope
/// references `kvFrames`, they arrive as cache hints on the decoded
/// request — a served model with a KV controller (e.g. the llama FFI
/// backend) restores real state from the named frames' pages; models
/// without one simply ignore the hints and decode cold.
///
/// Errors are typed on the wire: a failed generate answers
/// `{"error": …}`, which the client surfaces as [SidecarRemoteException]
/// — the transport never fabricates success in either direction.
final class RingSidecarHost {
  final VasterModel model;
  final SharedMemoryRing requestRing;
  final SharedMemoryRing responseRing;
  final Duration pollInterval;

  /// The wire codec — same instance-held shape as the client side.
  final SidecarEnvelopeCodec envelopeCodec;

  bool _stopping = false;
  bool _running = false;

  RingSidecarHost({
    required this.model,
    required this.requestRing,
    required this.responseRing,
    this.pollInterval = const Duration(milliseconds: 2),
    this.envelopeCodec = const SidecarEnvelopeCodec(),
  });

  /// Serves until [stop] is called. One request at a time — the ring
  /// protocol is SPSC by rule, and served backends may hold sequential
  /// state (one engine sequence).
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
      final action = envelopeCodec.actionOf(envelope);
      if (action != 'generate') {
        return jsonEncode({'error': 'unsupported action "$action"'});
      }
      final response =
          await model.generate(envelopeCodec.decodeGenerate(envelope));
      return jsonEncode(response.toJson());
    } on Object catch (e) {
      return jsonEncode({'error': e.toString()});
    }
  }
}
