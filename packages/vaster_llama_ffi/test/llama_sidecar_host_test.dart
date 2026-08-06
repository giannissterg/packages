@Tags(['llama'])
library;

import 'dart:io';

import 'package:test/test.dart';
import 'package:vaster_llama_ffi/vaster_llama_ffi.dart';
import 'package:vaster_mmap/vaster_mmap.dart';
import 'package:vaster_model/vaster_model.dart';

/// ZC-P5: the full ring topology — an [MmapVasterModel] client, the
/// [RingSidecarHost] serving a real engine, KV state riding as named
/// frames. The client and host share this test's event loop; the engine
/// runs on the worker isolate's thread.
void main() {
  final modelPath = Platform.environment['VASTER_LLAMA_TEST_MODEL'] ??
      '${Platform.environment['HOME']}/models/stories15M-q4_0.gguf';
  final available = File(modelPath).existsSync() &&
      File(LlamaBindings.defaultLibraryPath).existsSync();
  final skip = available
      ? null
      : 'needs $modelPath and ${LlamaBindings.defaultLibraryPath} '
          '(see docs/ZERO_COPY.md setup)';

  test('client ↔ sidecar over rings, with zero-copy KV frame reuse',
      () async {
    final stamp = DateTime.now().microsecondsSinceEpoch;
    final req = SharedMemoryRing(shmName: '/vsc_req_$stamp', capacity: 65536);
    final res = SharedMemoryRing(shmName: '/vsc_res_$stamp', capacity: 65536);
    final worker = await LlamaWorker.spawn(modelPath: modelPath);
    final kv = LlamaFfiKvCacheController(
        worker: worker, namePrefix: 'vsc_kv_${stamp % 100000}_');
    final host = RingSidecarHost(
      model: LlamaFfiVasterModel(worker: worker, kvController: kv),
      requestRing: req,
      responseRing: res,
    );
    final serving = host.serve();
    addTearDown(() async {
      host.stop();
      await serving;
      for (final handle in await kv.list()) {
        await kv.evict(handle);
      }
      await worker.close();
      req.close();
      res.close();
    });

    // The client side: hints lower to frame refs through the same
    // controller type acting as a KvFrameResolver.
    final client = MmapVasterModel(
      ring: req,
      responseRing: res,
      frameResolver: kv,
    );

    const knowledge = 'user: Story facts: Bo is a small brown dog.\n';
    const fingerprint = 'sidecar-fp-000111222333444555666777888999aabb';

    ModelRequest request({List<ContextCacheHint> hints = const []}) =>
        ModelRequest(
          messages: [
            ChatMessage.user('Story facts: Bo is a small brown dog.'),
            ChatMessage.user('Continue the story of Bo.'),
          ],
          cacheHints: hints,
        );

    // Cold round-trip over the rings.
    final cold = await client.generate(request());
    expect(cold.text, isNotEmpty);
    expect(cold.usage.cacheReadTokenCount, 0);
    expect(cold.usage.source, UsageSource.measured,
        reason: 'usage crossed the wire intact');

    // Materialize the prefix, call again with the hint: the ring carries
    // only the frame REF; the sidecar restores real KV state from pages.
    final handle = await kv.materialize(
        contentFingerprint: fingerprint, content: knowledge);
    final warm = await client.generate(request(hints: [
      const ContextCacheHint(
          regionId: 'facts', contentFingerprint: fingerprint),
    ]));
    expect(warm.usage.cacheReadTokenCount, handle.tokenCount,
        reason: 'restored prefix tokens were never re-decoded');
    expect(warm.text, cold.text,
        reason: 'zero-copy reuse must not change the completion');
  }, skip: skip);

  test('sidecar answers unknown actions and failures as typed errors',
      () async {
    final stamp = DateTime.now().microsecondsSinceEpoch;
    final req = SharedMemoryRing(shmName: '/vsce_req_$stamp', capacity: 65536);
    final res = SharedMemoryRing(shmName: '/vsce_res_$stamp', capacity: 65536);
    final worker = await LlamaWorker.spawn(modelPath: modelPath);
    final host = RingSidecarHost(
      model: LlamaFfiVasterModel(worker: worker),
      requestRing: req,
      responseRing: res,
    );
    final serving = host.serve();
    addTearDown(() async {
      host.stop();
      await serving;
      await worker.close();
      req.close();
      res.close();
    });

    req.writeString('{"action":"selfdestruct"}');
    final client = MmapVasterModel(ring: req, responseRing: res);
    // The next generate must see OUR error… but the pending error envelope
    // answers it first — which is exactly the point: errors are typed.
    await expectLater(
      client.generate(ModelRequest(messages: [ChatMessage.user('hi')])),
      throwsA(isA<SidecarRemoteException>()),
    );
  }, skip: skip);
}
