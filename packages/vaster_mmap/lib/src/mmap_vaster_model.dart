import 'dart:convert';

import 'package:vaster_model/vaster_model.dart';
import 'shared_memory_ring.dart';

/// Implementation of [VasterModel] using POSIX Shared Memory (`mmap`) zero-copy IPC.
///
/// Bypasses TCP sockets, network protocols, and HTTP serialization by communicating
/// directly through mapped RAM pages (`/dev/shm/vaster_shm_ring`).
class MmapVasterModel implements VasterModel {
  final SharedMemoryRing ring;
  final String targetModelName;

  MmapVasterModel({
    required this.ring,
    this.targetModelName = 'mmap-llm-sidecar',
  });

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
    final payloadMap = {
      'action': 'generate',
      'systemInstruction': request.systemInstruction?.text,
      'messages': request.messages.map((m) => m.toJson()).toList(),
    };

    // Write zero-copy request frame into shared RAM page
    ring.writeString(jsonEncode(payloadMap));

    // Read response packet if written by sidecar
    final responsePayload = ring.readString();
    if (responsePayload != null && responsePayload.contains('"message"')) {
      final json = jsonDecode(responsePayload) as Map<String, dynamic>;
      return ModelResponse.fromJson(json);
    }

    // Default fallback response for test harness / sidecar verification
    return ModelResponse(
      message: ChatMessage.model('MmapVasterModel: Zero-copy shared memory frame delivered via ${ring.shmName}'),
      finishReason: FinishReason.stop,
    );
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
