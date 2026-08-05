import 'package:vaster_model/vaster_model.dart';

import 'kv_frame_ref.dart';

/// The sidecar wire envelope (protocol v2) — **one codec, both
/// directions, one owner**. Clients ([MmapVasterModel]) encode with it;
/// sidecar hosts decode with it. The protocol's shape lives here and
/// nowhere else, so the two sides cannot drift.
///
/// ```json
/// { "action": "generate", "protocol": 2,
///   "systemInstruction": "...", "messages": [...],
///   "kvFrames": [{"frameName": "...", "contentFingerprint": "...", "tokenCount": 128}] }
/// ```
final class SidecarEnvelope {
  static const int protocolVersion = 2;

  SidecarEnvelope._();

  /// The envelope's action, or null when the payload is not an envelope.
  static String? actionOf(Map<String, dynamic> envelope) =>
      envelope['action'] as String?;

  /// Lowers a [ModelRequest] plus resolved frame refs onto the wire.
  /// Bulk context never rides here — pinned content travels as the named
  /// frames behind [frameRefs].
  static Map<String, dynamic> encodeGenerate(
          ModelRequest request, List<KvFrameRef> frameRefs) =>
      {
        'action': 'generate',
        'protocol': protocolVersion,
        'systemInstruction': request.systemInstruction?.text,
        'messages': request.messages.map((m) => m.toJson()).toList(),
        if (frameRefs.isNotEmpty)
          'kvFrames': frameRefs.map((r) => r.toJson()).toList(),
      };

  /// Rebuilds the [ModelRequest] a sidecar executes. `kvFrames` refs
  /// become cache hints — the serving model's controller re-resolves them
  /// by fingerprint and restores state from the named frames' pages.
  static ModelRequest decodeGenerate(Map<String, dynamic> envelope) {
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
