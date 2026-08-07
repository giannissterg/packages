import 'package:test/test.dart';
import 'package:vaster_resources/vaster_resources.dart';

/// Meter restore for checkpoint resume: no double-charge, no free ride, no
/// spurious re-trip.
void main() {
  group('ResourceTracker.restoreConsumed', () {
    test('restored counters continue from, not restart at, their values', () {
      final tracker = ResourceTracker(quota: const ResourceQuota(maxTokenBudget: 1000));
      tracker.restoreConsumed(tokens: 400, cost: 0.02, toolCalls: 3);

      expect(tracker.consumedTokens, 400);
      expect(tracker.consumedCost, 0.02);
      expect(tracker.toolCallCount, 3);

      tracker.consumeTokens(100);
      expect(tracker.consumedTokens, 500, reason: 'consumption continues from the restored value');
    });

    test('restore does not re-trip a quota the original run survived, but '
        'the next breach does', () {
      final tracker = ResourceTracker(quota: const ResourceQuota(maxTokenBudget: 100));
      // Captured exactly at the limit — legal when captured.
      tracker.restoreConsumed(tokens: 100, cost: 0, toolCalls: 0);

      expect(
        () => tracker.consumeTokens(1),
        throwsA(isA<QuotaExceededException>()),
        reason: 'enforcement resumes with real consumption',
      );
    });
  });
}
