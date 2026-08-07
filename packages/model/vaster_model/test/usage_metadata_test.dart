import 'package:test/test.dart';
import 'package:vaster_model/vaster_model.dart';

void main() {
  group('UsageMetadata', () {
    test('full round-trip preserves every field', () {
      const usage = UsageMetadata(
        promptTokenCount: 1200,
        candidatesTokenCount: 300,
        thoughtsTokenCount: 50,
        cacheReadTokenCount: 900,
        cacheCreationTokenCount: 100,
        costUsd: 0.042,
        source: UsageSource.measured,
      );

      final restored = UsageMetadata.fromJson(usage.toJson());

      expect(restored.promptTokenCount, equals(1200));
      expect(restored.candidatesTokenCount, equals(300));
      expect(restored.thoughtsTokenCount, equals(50));
      expect(restored.cacheReadTokenCount, equals(900));
      expect(restored.cacheCreationTokenCount, equals(100));
      expect(restored.totalTokenCount, equals(1200 + 300 + 50));
      expect(restored.costUsd, equals(0.042));
      expect(restored.source, equals(UsageSource.measured));
    });

    test('legacy three-field payloads parse with honest defaults', () {
      final restored = UsageMetadata.fromJson({
        'promptTokenCount': 10,
        'candidatesTokenCount': 20,
        'totalTokenCount': 30,
      });

      expect(restored.promptTokenCount, equals(10));
      expect(restored.totalTokenCount, equals(30));
      expect(restored.cacheReadTokenCount, equals(0));
      expect(restored.costUsd, isNull);
      expect(restored.source, equals(UsageSource.estimated));
    });

    test('default-valued new fields are not emitted (payload back-compat)', () {
      const usage = UsageMetadata(promptTokenCount: 5, candidatesTokenCount: 7);
      expect(
        usage.toJson(),
        equals({'promptTokenCount': 5, 'candidatesTokenCount': 7, 'totalTokenCount': 12}),
      );
    });

    test('operator + sums fields, null-aware cost, taints source', () {
      const measured = UsageMetadata(
        promptTokenCount: 100,
        candidatesTokenCount: 10,
        cacheReadTokenCount: 80,
        costUsd: 0.01,
        source: UsageSource.measured,
      );
      const estimated = UsageMetadata(promptTokenCount: 40, candidatesTokenCount: 4);

      final both = measured + measured;
      expect(both.promptTokenCount, equals(200));
      expect(both.cacheReadTokenCount, equals(160));
      expect(both.costUsd, equals(0.02));
      expect(both.source, equals(UsageSource.measured));

      final tainted = measured + estimated;
      expect(tainted.promptTokenCount, equals(140));
      expect(tainted.costUsd, equals(0.01)); // null + x = x
      expect(tainted.source, equals(UsageSource.estimated));

      final noCost = estimated + estimated;
      expect(noCost.costUsd, isNull);
    });
  });
}
