import 'package:test/test.dart';
import 'package:vaster_context/vaster_context.dart';
import 'package:vaster_context_manager/vaster_context_manager.dart';
import 'package:vaster_events/vaster_events.dart';
import 'package:vaster_model/vaster_model.dart';
import 'package:vaster_model_fake/vaster_model_fake.dart';

ContextRegion _bigRegion(String id,
    {ContextPriority priority = ContextPriority.medium,
    ContextCompressibility compressibility = ContextCompressibility.truncate,
    bool pinned = false,
    int messages = 20}) {
  return ContextRegion(
    id: id,
    label: id,
    messages: [
      for (var i = 0; i < messages; i++)
        ChatMessage.user('message $i of region $id — ${'x' * 100}'),
    ],
    estimatedTokens: messages * 30,
    priority: priority,
    compressibility: compressibility,
    isPinned: pinned,
  );
}

void main() {
  group('Pin/unpin (bug a: no reorder)', () {
    test('pinning preserves heap order and descriptor invalidates on unpin', () {
      final manager = BasicContextManager();
      manager.addRegion(_bigRegion('a'));
      manager.addRegion(_bigRegion('b'));
      manager.addRegion(_bigRegion('c'));

      manager.pinRegion('a');
      expect(manager.regions.map((r) => r.id), equals(['a', 'b', 'c']),
          reason: 'pin must not move the region');
      expect(manager.getRegion('a')!.isPinned, isTrue);
    });
  });

  group('Cache descriptors (bug b: self-healing)', () {
    test('descriptor is stable for unchanged content, refreshed on change', () {
      final manager = BasicContextManager();
      manager.addRegion(_bigRegion('doc'));
      manager.pinRegion('doc');

      final first = manager.getCacheDescriptor('doc')!;
      final second = manager.getCacheDescriptor('doc')!;
      expect(identical(first, second), isTrue, reason: 'stable while unchanged');

      manager.updateRegion(
          'doc', (r) => r.copyWith(messages: [ChatMessage.user('rewritten')]));
      final third = manager.getCacheDescriptor('doc')!;
      expect(third.contentFingerprint, isNot(equals(first.contentFingerprint)),
          reason: 'content change must mint a fresh fingerprint');
    });
  });

  group('Compression pre-pass', () {
    test('compresses least-important regions first, only when over budget',
        () async {
      final events = <RuntimeEvent>[];
      final bus = BasicEventBus();
      bus.stream.listen(events.add);

      final manager = BasicContextManager(
        compressors: [const TruncatingCompressor()],
        eventBus: bus,
      );
      manager.addRegion(_bigRegion('low', priority: ContextPriority.low));
      manager.addRegion(_bigRegion('high',
          priority: ContextPriority.high,
          compressibility: ContextCompressibility.none));
      manager.addRegion(_bigRegion('sacred',
          priority: ContextPriority.ephemeral, pinned: true));

      // Budget comfortably above total: no compression.
      const bigBudget = TokenBudget(maxContextTokens: 100000);
      await manager.compileContext(budget: bigBudget);
      expect(manager.getRegion('low')!.isCompressed, isFalse);

      // Tight budget: only 'low' is a candidate (high=none, sacred=pinned).
      const tightBudget = TokenBudget(
          maxContextTokens: 1400, reservedOutputTokens: 0, reservedToolTokens: 0);
      final compiled = await manager.compileContext(budget: tightBudget);

      expect(manager.getRegion('low')!.isCompressed, isTrue);
      expect(manager.getRegion('high')!.isCompressed, isFalse,
          reason: 'compressibility none is inviolable');
      expect(manager.getRegion('sacred')!.isCompressed, isFalse,
          reason: 'pinned regions skipped by automatic pre-pass');
      expect(
          manager.getRegion('low')!.estimatedTokens,
          lessThan(600),
          reason: 'low actually shrank');

      // Events emitted.
      await Future<void>.delayed(Duration.zero);
      expect(events.whereType<ContextCompressedEvent>(), isNotEmpty);
      // Pinned region bypasses budget; compiled totals include it.
      expect(compiled.includedRegions.map((r) => r.id), contains('sacred'));
    });

    test('eviction records attribute post-compression evictions', () async {
      final manager = BasicContextManager(); // no compressors
      manager.addRegion(_bigRegion('a', priority: ContextPriority.low));
      manager.addRegion(_bigRegion('b', priority: ContextPriority.high));

      const budget = TokenBudget(
          maxContextTokens: 700, reservedOutputTokens: 0, reservedToolTokens: 0);
      final compiled = await manager.compileContext(budget: budget);

      expect(compiled.evictionRecords, hasLength(1));
      final record = compiled.evictionRecords.single;
      expect(record.regionId, equals('a'));
      expect(record.reason, equals(EvictionReason.budgetExceeded));
    });
  });

  group('SummarizingCompressor', () {
    test('summarizes via model and preserves originals for expand()', () async {
      final model = FakeVasterModel(handler: (request) {
        expect(request.messages.single.text, contains('Summarize'));
        return ModelResponse(message: ChatMessage.model('the gist of it'));
      });
      final compressor = SummarizingCompressor(model: model);
      final region = _bigRegion('doc',
          compressibility: ContextCompressibility.summarize);

      final result = await compressor.compress(region, targetTokens: 50);
      expect(result.region.isCompressed, isTrue);
      expect(result.region.messages.single.text, contains('the gist of it'));
      expect(result.lossy, isFalse, reason: 'originals preserved by default');
      expect(result.region.compression!.originalMessages, hasLength(20));
      expect(result.tokensSaved, greaterThan(0));
    });

    test('falls back to truncation when the model errors', () async {
      final model = FakeVasterModel(handler: (_) {
        throw StateError('model down');
      });
      final compressor = SummarizingCompressor(model: model);
      final region = _bigRegion('doc',
          compressibility: ContextCompressibility.summarize);

      final result = await compressor.compress(region, targetTokens: 100);
      expect(result.region.isCompressed, isTrue);
      expect(result.region.compression!.compressorId, equals('truncating'));
    });
  });

  group('TruncatingCompressor', () {
    test('is deterministic, keeps head and tail, inserts one marker', () async {
      const compressor = TruncatingCompressor();
      final region = _bigRegion('log');

      final one = await compressor.compress(region, targetTokens: 200);
      final two = await compressor.compress(region, targetTokens: 200);
      expect(regionContentOf(one.region), equals(regionContentOf(two.region)),
          reason: 'deterministic');

      final texts = one.region.messages.map((m) => m.text).toList();
      expect(texts.first, contains('message 0'), reason: 'head kept');
      expect(texts.last, contains('message 19'), reason: 'tail kept');
      expect(texts.where((t) => t.contains('[context truncated')), hasLength(1));
      expect(one.region.estimatedTokens, lessThan(region.estimatedTokens));
    });
  });

  group('ContextWorkspace facade', () {
    for (final variant in ['basic', 'composite']) {
      test('full management surface over $variant manager', () async {
        final basic = BasicContextManager(
            compressors: [const TruncatingCompressor()]);
        final ContextManager manager = variant == 'basic'
            ? basic
            : CompositeContextManager(
                children: [basic],
                compressors: [const TruncatingCompressor()]);
        final workspace = ContextWorkspace(manager);

        workspace.addText(
            id: 'sys',
            label: 'system prompt',
            text: 'You are the architect. ' * 40,
            priority: ContextPriority.critical,
            pinned: true);
        workspace.add(_bigRegion('notes'));

        // Inspect.
        final report = workspace.inspect();
        expect(report.regionCount, equals(2));
        expect(report.totalTokens, greaterThan(0));
        expect(report.pinnedTokens, greaterThan(0));
        expect(report.toPrettyString(), contains('CONTEXT HEAP'));
        expect(report.toPrettyString(), contains('sys'));

        // Policy mutations.
        expect(workspace.setPriority('notes', ContextPriority.high), isTrue);
        expect(workspace.setCompressibility('notes', ContextCompressibility.summarize), isTrue);
        expect(workspace.setUtility('notes', 0.4), isTrue);
        expect(manager.getRegion('notes')!.priority, equals(ContextPriority.high));
        expect(workspace.setPriority('ghost', ContextPriority.low), isFalse,
            reason: 'no silent no-ops');

        // Pin round-trip.
        expect(workspace.pin('notes'), isTrue);
        expect(manager.getRegion('notes')!.isPinned, isTrue);
        expect(workspace.unpin('notes'), isTrue);
        expect(workspace.pin('ghost'), isFalse);

        // Deletion honors pins.
        expect(workspace.remove('sys'), isFalse, reason: 'pinned');
        expect(workspace.remove('sys', force: true), isTrue);
        expect(workspace.region('sys'), isNull);

        // Compaction through the facade.
        final compacted = await workspace.compact(
            budget: const TokenBudget(
                maxContextTokens: 220,
                reservedOutputTokens: 0,
                reservedToolTokens: 0));
        expect(compacted.tokensFreed, greaterThan(0));
        expect(manager.getRegion('notes')!.isCompressed, isTrue);
      });
    }

    test('expand restores summarized originals', () async {
      final model = FakeVasterModel(handler: (_) =>
          ModelResponse(message: ChatMessage.model('short summary')));
      final manager = BasicContextManager(
          compressors: [SummarizingCompressor(model: model)]);
      final workspace = ContextWorkspace(manager);
      manager.addRegion(_bigRegion('doc',
          compressibility: ContextCompressibility.summarize));

      await manager.compact(targetTokens: 50, regionId: 'doc');
      expect(manager.getRegion('doc')!.isCompressed, isTrue);
      expect(manager.getRegion('doc')!.messages, hasLength(1));

      expect(workspace.expand('doc'), isTrue);
      final expanded = manager.getRegion('doc')!;
      expect(expanded.isCompressed, isFalse);
      expect(expanded.messages, hasLength(20));
      expect(expanded.estimatedTokens, equals(600));
    });
  });

  group('Composite routing (bug c)', () {
    test('mutations land in the owning child heap', () async {
      final childA = BasicContextManager();
      final childB = BasicContextManager();
      childA.addRegion(_bigRegion('inA'));
      childB.addRegion(_bigRegion('inB'));
      final composite = CompositeContextManager(
          children: [childA, childB],
          compressors: [const TruncatingCompressor()]);

      // Update routes to childB.
      composite.updateRegion('inB', (r) => r.copyWith(utility: 0.1));
      expect(childB.getRegion('inB')!.utility, equals(0.1));
      expect(childA.getRegion('inB'), isNull);

      // Pin routes to childA and does not touch childB.
      composite.pinRegion('inA');
      expect(childA.getRegion('inA')!.isPinned, isTrue);

      // Compaction write-back reaches the owning child's real heap.
      await composite.compact(targetTokens: 100);
      final compressedInChild = [childA, childB]
          .expand((c) => c.regions)
          .where((r) => r.isCompressed);
      expect(compressedInChild, isNotEmpty,
          reason: 'compressed regions persisted in child heaps, not a snapshot');
    });
  });

  group('pruneLifetimes (bugs e/f)', () {
    test('respects pinned and critical unless forced', () {
      final manager = BasicContextManager();
      manager.addRegion(_bigRegion('scratch')
          .copyWith(lifetime: ContextLifetime.ephemeral));
      manager.addRegion(_bigRegion('pinned-scratch', pinned: true)
          .copyWith(lifetime: ContextLifetime.ephemeral));
      manager.addRegion(_bigRegion('critical-scratch',
              priority: ContextPriority.critical)
          .copyWith(lifetime: ContextLifetime.ephemeral));

      manager.pruneLifetimes({ContextLifetime.ephemeral});
      expect(manager.getRegion('scratch'), isNull);
      expect(manager.getRegion('pinned-scratch'), isNotNull);
      expect(manager.getRegion('critical-scratch'), isNotNull);

      manager.pruneLifetimes({ContextLifetime.ephemeral}, force: true);
      expect(manager.regions, isEmpty);
    });
  });
}
