import 'package:test/test.dart';
import 'package:vaster_context/vaster_context.dart';
import 'package:vaster_context_manager/vaster_context_manager.dart';
import 'package:vaster_context_mmu/vaster_context_mmu.dart';
import 'package:vaster_kv/vaster_kv.dart';
import 'package:vaster_model/vaster_model.dart';

ContextRegion _region(String id, String text) => ContextRegion(
      id: id,
      label: id,
      messages: [ChatMessage.system(text)],
      estimatedTokens: text.length ~/ 4,
    );

void main() {
  group('ContextMmu — virtual to physical lowering', () {
    late BasicContextManager manager;
    late InMemoryKvCacheController controller;
    late ContextMmu mmu;

    setUp(() {
      manager = BasicContextManager();
      controller = InMemoryKvCacheController();
      mmu = ContextMmu(controller: controller);
    });

    test('first bind page-faults, second bind hits', () async {
      manager.heap.addRegion(_region('sys', 'You are the architect agent.'));
      manager.pinRegion('sys');

      final stats1 = MmuStats();
      final hints1 = await mmu.bindPinnedRegions(manager, stats: stats1);
      expect(stats1.faults, equals(1));
      expect(stats1.hits, equals(0));
      expect(hints1, hasLength(1));
      expect(mmu.pageTable['sys'], isNotNull);

      final stats2 = MmuStats();
      final hints2 = await mmu.bindPinnedRegions(manager, stats: stats2);
      expect(stats2.faults, equals(0));
      expect(stats2.hits, equals(1));
      expect(controller.materializations, equals(1),
          reason: 'physical prefill paid exactly once');
      expect(hints2.single.contentFingerprint,
          equals(hints1.single.contentFingerprint));
    });

    test('hint fingerprints match the context manager descriptors', () async {
      manager.heap.addRegion(_region('sys', 'stable system prompt'));
      manager.pinRegion('sys');

      final hints = await mmu.bindPinnedRegions(manager);
      final descriptor = manager.getCacheDescriptor('sys')!;
      expect(hints.single.contentFingerprint,
          equals(descriptor.contentFingerprint));
      expect(mmu.pageTable['sys']!.contentFingerprint,
          equals(descriptor.contentFingerprint));
    });

    test('content change under the same region id invalidates and re-faults',
        () async {
      manager.heap.addRegion(_region('doc', 'version one of the document'));
      manager.pinRegion('doc');
      await mmu.bindPinnedRegions(manager);
      final firstHandle = mmu.pageTable['doc']!;

      // Same id, new content (addRegion replaces same-id regions). Descriptors
      // cache by TTL, so unpin/pin to force re-derivation.
      manager.unpinRegion('doc');
      manager.heap.addRegion(_region('doc', 'version TWO of the document'));
      manager.pinRegion('doc');

      final stats = MmuStats();
      await mmu.bindPinnedRegions(manager, stats: stats);
      expect(stats.invalidations, equals(1));
      expect(stats.faults, equals(1));
      expect(mmu.pageTable['doc']!.contentFingerprint,
          isNot(equals(firstHandle.contentFingerprint)));
      expect(controller.evictions, equals(1), reason: 'stale frame freed');
    });

    test('LRU eviction under slot pressure re-faults evicted pages', () async {
      controller = InMemoryKvCacheController(maxSlots: 2);
      mmu = ContextMmu(controller: controller);

      for (final id in ['a', 'b', 'c']) {
        manager.heap.addRegion(_region(id, 'content for region $id'));
        manager.pinRegion(id);
      }

      await mmu.bindPinnedRegions(manager);
      // Three pinned pages through two physical slots: 3 faults, 1 eviction.
      expect(controller.materializations, equals(3));
      expect(controller.evictions, equals(1));

      // Rebinding all three pages sequentially through two LRU slots is the
      // textbook thrash pattern: every access evicts the page needed next,
      // so the rebind is all faults, no hits.
      final stats = MmuStats();
      await mmu.bindPinnedRegions(manager, stats: stats);
      expect(stats.faults, equals(3));
      expect(stats.hits, equals(0));
      expect(await controller.list(), hasLength(2),
          reason: 'physical slot count stays bounded');
    });

    test('flush frees all physical frames', () async {
      manager.heap.addRegion(_region('sys', 'prompt'));
      manager.pinRegion('sys');
      await mmu.bindPinnedRegions(manager);
      expect(await controller.list(), hasLength(1));

      await mmu.flush();
      expect(mmu.pageTable, isEmpty);
      expect(await controller.list(), isEmpty);
    });

    test('restoreAll loads mapped state; evicted frames re-fault on next bind',
        () async {
      manager.heap.addRegion(_region('sys', 'prompt'));
      manager.pinRegion('sys');
      await mmu.bindPinnedRegions(manager);

      await mmu.restoreAll();
      expect(controller.restores, equals(1));

      // Evict underneath the MMU; restoreAll must not throw.
      await controller.evict(mmu.pageTable['sys']!);
      await mmu.restoreAll(); // silent — page will re-fault on next bind

      final stats = MmuStats();
      await mmu.bindPinnedRegions(manager, stats: stats);
      expect(stats.faults, equals(1));
    });
  });
}
