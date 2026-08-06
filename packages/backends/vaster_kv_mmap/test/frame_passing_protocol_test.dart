import 'dart:async';
import 'dart:convert';

import 'package:test/test.dart';
import 'package:vaster_context/vaster_context.dart';
import 'package:vaster_context_manager/vaster_context_manager.dart';
import 'package:vaster_context_mmu/vaster_context_mmu.dart';
import 'package:vaster_kv_mmap/vaster_kv_mmap.dart';
import 'package:vaster_mmap/vaster_mmap.dart';
import 'package:vaster_model/vaster_model.dart';

void main() {
  group('MmapVasterModel frame-passing protocol (v2)', () {
    test(
        'end-to-end: MMU materializes pinned context, sidecar prefills from the '
        'named frame, and context bytes never cross the ring', () async {
      final runId = DateTime.now().microsecondsSinceEpoch;
      final pinnedContent = 'PINNED-CONTEXT-$runId: the architect designs Vaster.';

      // ── VM side: pin a region and page it into shared memory ────────────
      final manager = BasicContextManager();
      manager.heap.addRegion(ContextRegion(
        id: 'sys',
        label: 'system context',
        messages: [ChatMessage.system(pinnedContent)],
        estimatedTokens: 24,
      ));
      manager.pinRegion('sys');

      final controller = MmapKvCacheController();
      final mmu = ContextMmu(controller: controller);
      final hints = await mmu.bindPinnedRegions(manager);
      expect(hints, hasLength(1));

      // ── Transport: duplex rings ─────────────────────────────────────────
      final requestRing = SharedMemoryRing(shmName: '/vreq_$runId', capacity: 64 * 1024);
      final responseRing = SharedMemoryRing(shmName: '/vres_$runId', capacity: 64 * 1024);
      addTearDown(() {
        requestRing.close();
        responseRing.close();
      });

      final model = MmapVasterModel(
        ring: requestRing,
        responseRing: responseRing,
        frameResolver: controller,
        responseTimeout: const Duration(seconds: 2),
      );

      // ── Fake sidecar: polls the request ring, prefills from the frame ──
      String? envelopeSeenBySidecar;
      final sidecar = () async {
        while (true) {
          final payload = requestRing.readString();
          if (payload == null) {
            await Future<void>.delayed(const Duration(milliseconds: 2));
            continue;
          }
          envelopeSeenBySidecar = payload;
          final envelope = jsonDecode(payload) as Map<String, dynamic>;
          expect(envelope['protocol'], equals(2));

          // Attach the advertised frame and read its physical pages —
          // the sidecar's zero-copy prefill source.
          final frameRef = KvFrameRef.fromJson(Map<String, dynamic>.from(
              (envelope['kvFrames'] as List).single as Map));
          final frame = SharedMemoryFrame.attach(frameRef.frameName);
          final prefill = utf8.decode(frame.bytes);
          frame.close();

          // Answer with proof of what was prefilled.
          final response = ModelResponse(
            message: ChatMessage.model(
                'prefilled ${frameRef.tokenCount} tokens from ${frameRef.frameName}: '
                '${prefill.substring(0, 20)}'),
          );
          responseRing.writeString(jsonEncode(response.toJson()));
          return;
        }
      }();

      // ── Generate with cache hints — the frame ref rides the envelope ────
      final response = await model.generate(ModelRequest(
        messages: [ChatMessage.user('continue the design')],
        cacheHints: hints,
      ));
      await sidecar;

      // The sidecar genuinely prefilled from the shared frame.
      expect(response.text, contains('prefilled 24 tokens'));
      expect(response.text, contains('PINNED-CONTEXT'));

      // The decisive property: the pinned context bytes are NOT in the wire
      // envelope — only the frame name is. Bulk context never crossed the ring.
      expect(envelopeSeenBySidecar, isNotNull);
      expect(envelopeSeenBySidecar, isNot(contains(pinnedContent)));
      expect(envelopeSeenBySidecar, contains('vaster_kv_'));
      expect(envelopeSeenBySidecar, contains('continue the design'),
          reason: 'the live turn itself still rides the ring');

      await mmu.flush();
    });

    test('without a resolver the envelope carries no kvFrames (protocol compat)',
        () async {
      final runId = DateTime.now().microsecondsSinceEpoch;
      final requestRing = SharedMemoryRing(shmName: '/vreq2_$runId', capacity: 64 * 1024);
      final responseRing = SharedMemoryRing(shmName: '/vres2_$runId', capacity: 64 * 1024);
      addTearDown(() {
        requestRing.close();
        responseRing.close();
      });

      final model = MmapVasterModel(
        ring: requestRing,
        responseRing: responseRing,
        responseTimeout: const Duration(milliseconds: 100),
      );

      // No sidecar is listening: the envelope still lands on the ring, and
      // the transport reports absence honestly instead of faking success.
      await expectLater(
        model.generate(ModelRequest(
          messages: [ChatMessage.user('hello')],
          cacheHints: const [
            ContextCacheHint(regionId: 'r', contentFingerprint: 'deadbeef'),
          ],
        )),
        throwsA(isA<SidecarUnavailableException>()),
      );

      final envelope =
          jsonDecode(requestRing.readString()!) as Map<String, dynamic>;
      expect(envelope.containsKey('kvFrames'), isFalse);
    });
  });
}
