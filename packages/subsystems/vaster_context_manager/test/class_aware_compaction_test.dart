import 'package:test/test.dart';
import 'package:vaster_context/vaster_context.dart';
import 'package:vaster_context_manager/vaster_context_manager.dart';
import 'package:vaster_model/vaster_model.dart';

void main() {
  ContextRegion bigRegion(String id, {String? classId, int messages = 12}) => ContextRegion(
    id: id,
    label: id,
    messages: [for (var i = 0; i < messages; i++) ChatMessage.user('message $i of $id — ${'x' * 80}')],
    estimatedTokens: 1000,
    classId: classId,
  );

  test('inherited compressibility compresses knowledge-class regions', () async {
    // The region declares NO compressibility — it inherits `summarize` from
    // the knowledge class (which the truncating compressor serves as a
    // fallback level here).
    final compactor = ContextCompactor(compressors: const [TruncatingCompressor(keepTailMessages: 1)]);

    final region = bigRegion('doc', classId: 'knowledge');
    expect(region.compressibility, isNull);

    ContextRegion? compressed;
    final report = await compactor.compact(
      regions: [region],
      targetTokens: 200,
      apply: (r) => compressed = r,
    );

    expect(report.tokensFreed, greaterThan(0));
    expect(compressed, isNotNull);
    expect(compressed!.isCompressed, isTrue);
  });

  test('never-eviction classes are immune to compaction', () async {
    final compactor = ContextCompactor(compressors: const [TruncatingCompressor(keepTailMessages: 1)]);

    final report = await compactor.compact(
      // Even with compressibility explicitly set, a system-class region is
      // immutable under pressure.
      regions: [
        bigRegion(
          'sys',
          classId: 'system',
        ).copyWith(compressibility: ContextCompressibility.truncate, isPinned: false),
      ],
      targetTokens: 100,
      includePinned: true,
      apply: (_) => fail('system class must never be compressed'),
    );

    expect(report.entries, isEmpty);
  });
}
