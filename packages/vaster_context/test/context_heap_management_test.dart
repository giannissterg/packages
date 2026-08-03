import 'package:test/test.dart';
import 'package:vaster_context/vaster_context.dart';
import 'package:vaster_model/vaster_model.dart';

ContextRegion _region(String id, String text,
        {bool pinned = false, ContextPriority priority = ContextPriority.medium}) =>
    ContextRegion.text(
      id: id,
      label: id,
      role: Role.user,
      text: text,
      isPinned: pinned,
      priority: priority,
    );

void main() {
  group('ContextHeap management primitives', () {
    test('updateRegion mutates in place without reordering', () {
      final heap = ContextHeap([_region('a', 'aa'), _region('b', 'bb'), _region('c', 'cc')]);

      final ok = heap.updateRegion('b', (r) => r.copyWith(isPinned: true));
      expect(ok, isTrue);
      expect(heap.regions.map((r) => r.id), equals(['a', 'b', 'c']),
          reason: 'order preserved');
      expect(heap.getRegion('b')!.isPinned, isTrue);

      expect(heap.updateRegion('ghost', (r) => r), isFalse);
    });

    test('removeRegion refuses pinned regions unless forced', () {
      final heap = ContextHeap([_region('p', 'pinned', pinned: true)]);
      expect(heap.removeRegion('p'), isFalse);
      expect(heap.getRegion('p'), isNotNull);
      expect(heap.removeRegion('p', force: true), isTrue);
      expect(heap.getRegion('p'), isNull);
    });

    test('clearNonCritical keeps pinned regions unless forced', () {
      final heap = ContextHeap([
        _region('crit', 'x', priority: ContextPriority.critical),
        _region('pinned', 'y', pinned: true, priority: ContextPriority.low),
        _region('plain', 'z', priority: ContextPriority.low),
      ]);
      heap.clearNonCritical();
      expect(heap.regions.map((r) => r.id), containsAll(['crit', 'pinned']));
      expect(heap.getRegion('plain'), isNull);

      heap.clearNonCritical(force: true);
      expect(heap.regions.map((r) => r.id), equals(['crit']));
    });

    test('upsertFromSource preserves heap-side policy and compressed shadows', () {
      final heap = ContextHeap();
      final source = _region('doc', 'original document content');
      heap.upsertFromSource(source, fingerprintOf: regionFingerprintOf);

      // Heap-side policy mutations.
      heap.updateRegion(
          'doc',
          (r) => r.copyWith(
              isPinned: true,
              priority: ContextPriority.high,
              compressibility: ContextCompressibility.summarize));

      // Re-sync with unchanged source: policy survives.
      heap.upsertFromSource(_region('doc', 'original document content'),
          fingerprintOf: regionFingerprintOf);
      final synced = heap.getRegion('doc')!;
      expect(synced.isPinned, isTrue);
      expect(synced.priority, equals(ContextPriority.high));
      expect(synced.compressibility, equals(ContextCompressibility.summarize));

      // Compress it (shadow): source fingerprint recorded from the ORIGINAL.
      final originalFp = regionFingerprintOf(synced);
      heap.updateRegion(
          'doc',
          (r) => r.copyWith(
                messages: [ChatMessage.user('[summary] doc')],
                estimatedTokens: 4,
                compression: CompressionInfo(
                  compressorId: 'test',
                  tokensBefore: r.estimatedTokens,
                  sourceFingerprint: originalFp,
                ),
              ));

      // Re-sync with UNCHANGED source: compressed shadow survives.
      heap.upsertFromSource(_region('doc', 'original document content'),
          fingerprintOf: regionFingerprintOf);
      expect(heap.getRegion('doc')!.isCompressed, isTrue);
      expect(regionContentOf(heap.getRegion('doc')!), contains('[summary]'));

      // Re-sync with CHANGED source: source wins, compression cleared,
      // policy still preserved.
      heap.upsertFromSource(_region('doc', 'brand new document content'),
          fingerprintOf: regionFingerprintOf);
      final replaced = heap.getRegion('doc')!;
      expect(replaced.isCompressed, isFalse);
      expect(regionContentOf(replaced), contains('brand new'));
      expect(replaced.isPinned, isTrue, reason: 'policy still preserved');
    });

    test('replaceRegion keeps index for existing ids, appends new ones', () {
      final heap = ContextHeap([_region('a', 'aa'), _region('b', 'bb')]);
      heap.replaceRegion(_region('a', 'AA!'));
      expect(heap.regions.map((r) => r.id), equals(['a', 'b']));
      expect(regionContentOf(heap.getRegion('a')!), equals('AA!'));
      heap.replaceRegion(_region('c', 'cc'));
      expect(heap.regions.map((r) => r.id), equals(['a', 'b', 'c']));
    });
  });

  group('New model surface', () {
    test('compressibility parse and copyWith clearCompression', () {
      expect(ContextCompressibility.parse('summarize'),
          equals(ContextCompressibility.summarize));
      expect(ContextCompressibility.parse('bogus'),
          equals(ContextCompressibility.none));
      expect(ContextPriority.parse('critical'), equals(ContextPriority.critical));
      expect(ContextLifetime.parse('step'), equals(ContextLifetime.step));

      final region = _region('r', 'text').copyWith(
        compression: CompressionInfo(
            compressorId: 't', tokensBefore: 10, sourceFingerprint: 'fp'),
      );
      expect(region.isCompressed, isTrue);
      expect(region.copyWith(clearCompression: true).isCompressed, isFalse);
    });
  });
}
