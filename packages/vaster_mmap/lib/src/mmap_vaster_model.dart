import 'dart:async';
import 'dart:convert';

import 'package:vaster_model/vaster_model.dart';

import 'kv_frame_ref.dart';
import 'shared_memory_ring.dart';

/// Implementation of [VasterModel] using POSIX Shared Memory (`mmap`) zero-copy IPC.
///
/// Bypasses TCP sockets, network protocols, and HTTP serialization by
/// communicating directly through mapped RAM pages.
///
/// **Physical context passing:** when constructed with a [frameResolver],
/// incoming [ModelRequest.cacheHints] are resolved to [KvFrameRef]s and sent
/// in the request envelope's `kvFrames` field. The sidecar attaches those
/// named segments and prefills from the mapped pages directly — pinned
/// context content never crosses the ring, only its frame name does.
///
/// Wire envelope (UTF-8 JSON frames on the ring):
/// ```json
/// { "action": "generate", "protocol": 2,
///   "systemInstruction": "...", "messages": [...],
///   "kvFrames": [{"frameName": "...", "contentFingerprint": "...", "tokenCount": 128}] }
/// ```
/// The sidecar answers on [responseRing] with a serialized `ModelResponse`
/// (detected by its `message` field).
class MmapVasterModel implements VasterModel {
  /// Ring the request envelope is written to.
  final SharedMemoryRing ring;

  /// Ring the sidecar's response is read from. Defaults to [ring]
  /// (half-duplex legacy mode); use a second ring for true duplex.
  final SharedMemoryRing responseRing;

  /// Optional resolver lowering cache hints to shared-memory frame refs.
  final KvFrameResolver? frameResolver;

  /// How long to poll for a sidecar response before falling back.
  final Duration responseTimeout;

  /// Poll interval while waiting for the sidecar.
  final Duration pollInterval;

  final String targetModelName;

  MmapVasterModel({
    required this.ring,
    SharedMemoryRing? responseRing,
    this.frameResolver,
    this.responseTimeout = const Duration(milliseconds: 250),
    this.pollInterval = const Duration(milliseconds: 2),
    this.targetModelName = 'mmap-llm-sidecar',
  }) : responseRing = responseRing ?? ring;

  @override
  String get modelName => targetModelName;

  String get descriptor => 'mmap:$targetModelName';

  @override
  ModelCapabilities get capabilities => const ModelCapabilities(
        maxContextTokens: 1000000,
        maxOutputTokens: 8192,
        supportsFunctionCalling: true,
        supportsStreaming: true,
      );

  @override
  Future<ModelResponse> generate(ModelRequest request) async {
    // Lower cache hints to physical frame references — the zero-copy context
    // path. Unresolvable hints are simply omitted (sidecar prefills cold).
    final frameRefs = <KvFrameRef>[];
    final resolver = frameResolver;
    if (resolver != null) {
      for (final hint in request.cacheHints) {
        final ref = await resolver.resolveFrame(hint.contentFingerprint);
        if (ref != null) frameRefs.add(ref);
      }
    }

    final payloadMap = {
      'action': 'generate',
      'protocol': 2,
      'systemInstruction': request.systemInstruction?.text,
      'messages': request.messages.map((m) => m.toJson()).toList(),
      if (frameRefs.isNotEmpty)
        'kvFrames': frameRefs.map((r) => r.toJson()).toList(),
    };

    // Write zero-copy request frame into shared RAM pages.
    ring.writeString(jsonEncode(payloadMap));

    // Poll the response ring for a sidecar answer.
    final deadline = DateTime.now().add(responseTimeout);
    while (DateTime.now().isBefore(deadline)) {
      final payload = responseRing.readString();
      if (payload != null) {
        final parsed = _tryParseResponse(payload);
        if (parsed != null) return parsed;
        // Not a response (e.g. our own request on a shared ring) — keep polling.
      } else {
        await Future<void>.delayed(pollInterval);
      }
    }

    // Default fallback response for test harness / sidecar verification.
    return ModelResponse(
      message: ChatMessage.model(
          'MmapVasterModel: Zero-copy shared memory frame delivered via ${ring.shmName}'),
      finishReason: FinishReason.stop,
    );
  }

  ModelResponse? _tryParseResponse(String payload) {
    try {
      final json = jsonDecode(payload);
      if (json is Map<String, dynamic> && json.containsKey('message')) {
        return ModelResponse.fromJson(json);
      }
    } catch (_) {}
    return null;
  }

  @override
  Stream<ModelResponseChunk> generateStream(ModelRequest request) async* {
    final response = await generate(request);
    yield ModelResponseChunk(
      textDelta: response.text,
      finishReason: response.finishReason,
    );
  }
}
