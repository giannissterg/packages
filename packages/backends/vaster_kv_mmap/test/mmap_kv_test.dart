import 'dart:convert';

import 'package:test/test.dart';
import 'package:vaster_context/vaster_context.dart';
import 'package:vaster_context_manager/vaster_context_manager.dart';
import 'package:vaster_context_mmu/vaster_context_mmu.dart';
import 'package:vaster_kv_mmap/vaster_kv_mmap.dart';
import 'package:vaster_model/vaster_model.dart';

void main() {
  // Unique content per run so stale segments from earlier runs never alias.
  final runId = DateTime.now().microsecondsSinceEpoch;

  group('MmapKvCacheController — shared-memory physical frames', () {
    test('materialize creates a frame; a second controller instance discovers '
        'it by fingerprint (cross-process attach path)', () async {
      final content = 'pinned system prompt $runId';
      final fingerprint = 'a1b2c3d4e5f60718$runId';

      final producer = MmapKvCacheController();
      final handle = await producer.materialize(
        contentFingerprint: fingerprint,
        content: content,
        tokenEstimate: 42,
      );
      expect(handle.backend, equals('mmap'));
      expect(handle.tokenCount, equals(42));

      // A *fresh* controller (simulating another process) finds the frame via
      // segment attach — no re-materialization.
      final consumer = MmapKvCacheController();
      final discovered = await consumer.lookup(fingerprint);
      expect(discovered, isNotNull);
      expect(discovered!.contentFingerprint, equals(fingerprint));
      expect(discovered.tokenCount, equals(42),
          reason: 'metadata travels through the frame header');
      expect(utf8.decode(consumer.readState(discovered)), equals(content));

      await producer.evict(handle);
      consumer.detachAll();
    });

    test('both attachments view the same physical pages (zero-copy)', () async {
      final fingerprint = 'feedfacecafe0000$runId';
      final producer = MmapKvCacheController();
      final handle = await producer.materialize(
        contentFingerprint: fingerprint,
        content: 'zero copy proof $runId',
      );

      final consumer = MmapKvCacheController();
      final consumerHandle = (await consumer.lookup(fingerprint))!;

      // Mutate through the producer's view; the consumer's view sees it —
      // proof both map the same physical memory rather than holding copies.
      producer.readState(handle)[0] = 0x58; // 'X'
      expect(consumer.readState(consumerHandle)[0], equals(0x58));

      await producer.evict(handle);
      consumer.detachAll();
    });

    test('evict destroys the segment for future attachers', () async {
      final fingerprint = 'deadbeef00000000$runId';
      final controller = MmapKvCacheController();
      final handle = await controller.materialize(
        contentFingerprint: fingerprint,
        content: 'ephemeral $runId',
      );
      await controller.evict(handle);

      final fresh = MmapKvCacheController();
      expect(await fresh.lookup(fingerprint), isNull);
    });
  });

  group('ContextMmu over shared memory — cross-process page hits', () {
    test('a second MMU in a fresh controller hits pages the first faulted in',
        () async {
      final region = ContextRegion(
        id: 'shared_sys',
        label: 'shared system prompt',
        messages: [ChatMessage.system('cross-process context $runId')],
        estimatedTokens: 16,
      );

      // Process A: page-fault the pinned region into shared memory.
      final managerA = BasicContextManager();
      managerA.heap.addRegion(region);
      managerA.pinRegion('shared_sys');
      final controllerA = MmapKvCacheController();
      final mmuA = ContextMmu(controller: controllerA);
      final statsA = MmuStats();
      await mmuA.bindPinnedRegions(managerA, stats: statsA);
      expect(statsA.faults, equals(1));

      // Process B: same pinned content, fresh controller + MMU — the physical
      // frame is discovered in shared memory, so binding is a pure page hit.
      final managerB = BasicContextManager();
      managerB.heap.addRegion(region);
      managerB.pinRegion('shared_sys');
      final controllerB = MmapKvCacheController();
      final mmuB = ContextMmu(controller: controllerB);
      final statsB = MmuStats();
      final hints = await mmuB.bindPinnedRegions(managerB, stats: statsB);

      expect(statsB.faults, equals(0), reason: 'prefill never paid twice');
      expect(statsB.hits, equals(1));
      expect(hints.single.regionId, equals('shared_sys'));

      await mmuA.flush(); // destroys the shared frame
      controllerB.detachAll();
    });
  });
}
