import 'dart:async';

import 'package:test/test.dart';
import 'package:vaster_mmap/vaster_mmap.dart';
import 'package:vaster_model/vaster_model.dart';

/// The ring host is backend-agnostic transport code: here it serves a
/// hand-rolled non-llama model, proving no engine-specific coupling.
final class _EchoModel implements VasterModel {
  @override
  String get modelName => 'echo';

  @override
  ModelCapabilities get capabilities => const ModelCapabilities();

  @override
  Future<ModelResponse> generate(ModelRequest request) async =>
      ModelResponse(
        message: ChatMessage.model('echo: ${request.messages.last.text} '
            '(hints: ${request.cacheHints.length})'),
        usage: const UsageMetadata(
            promptTokenCount: 3, source: UsageSource.measured),
      );

  @override
  Stream<ModelResponseChunk> generateStream(ModelRequest request) async* {
    final r = await generate(request);
    yield ModelResponseChunk(textDelta: r.text, finishReason: r.finishReason);
  }
}

void main() {
  test('RingSidecarHost serves any VasterModel over duplex rings', () async {
    final stamp = DateTime.now().microsecondsSinceEpoch;
    final req = SharedMemoryRing(shmName: '/vrh_req_$stamp', capacity: 65536);
    final res = SharedMemoryRing(shmName: '/vrh_res_$stamp', capacity: 65536);
    final host = RingSidecarHost(
        model: _EchoModel(), requestRing: req, responseRing: res);
    final serving = host.serve();
    addTearDown(() async {
      host.stop();
      await serving;
      req.close();
      res.close();
    });

    final client = MmapVasterModel(ring: req, responseRing: res);
    final response = await client.generate(ModelRequest(
      messages: [ChatMessage.user('over the pages')],
      cacheHints: const [
        ContextCacheHint(regionId: 'r', contentFingerprint: 'unresolvable'),
      ],
    ));

    expect(response.text, contains('echo: over the pages'));
    expect(response.text, contains('hints: 0'),
        reason: 'no resolver on the client — hints lower to nothing');
    expect(response.usage.promptTokenCount, 3,
        reason: 'usage crossed the wire intact');

    // Unknown actions answer as typed remote errors.
    req.writeString('{"action":"nope"}');
    await expectLater(
      client.generate(ModelRequest(messages: [ChatMessage.user('x')])),
      throwsA(isA<SidecarRemoteException>()),
    );
  });
}
