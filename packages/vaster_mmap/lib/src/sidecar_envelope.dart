import 'package:vaster_model/vaster_model.dart';

import 'kv_frame_ref.dart';

/// Protocol version of the sidecar wire envelope.
const int sidecarProtocolVersion = 2;

/// The sidecar wire envelope codec (protocol v2) — **one codec, both
/// directions, one owner**, and an *instance*: clients
/// ([MmapVasterModel]) and hosts ([RingSidecarHost]) hold one (const by
/// default), so the parsing logic is testable in isolation and a future
/// protocol version composes in as another codec instead of a static
/// rewrite.
///
/// ```json
/// { "action": "generate", "protocol": 2,
///   "systemInstruction": "...", "messages": [...],
///   "kvFrames": [{"frameName": "...", "contentFingerprint": "...", "tokenCount": 128}] }
/// ```
final class SidecarEnvelopeCodec {
  const SidecarEnvelopeCodec();

  /// The envelope's action, or null when the payload is not an envelope.
  String? actionOf(Map<String, dynamic> envelope) =>
      envelope['action'] as String?;

  /// Lowers a [ModelRequest] plus resolved frame refs onto the wire.
  /// Bulk context never rides here — pinned content travels as the named
  /// frames behind [frameRefs].
  Map<String, dynamic> encodeGenerate(
          ModelRequest request, List<KvFrameRef> frameRefs) =>
      {
        'action': 'generate',
        'protocol': sidecarProtocolVersion,
        'systemInstruction': request.systemInstruction?.text,
        'messages': request.messages.map((m) => m.toJson()).toList(),
        if (frameRefs.isNotEmpty)
          'kvFrames': frameRefs.map((r) => r.toJson()).toList(),
      };

  /// Rebuilds the [ModelRequest] a sidecar executes. `kvFrames` refs
  /// become cache hints — the serving model's controller re-resolves them
  /// by fingerprint and restores state from the named frames' pages.
  ModelRequest decodeGenerate(Map<String, dynamic> envelope) {
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
