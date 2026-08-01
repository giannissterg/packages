import 'package:test/test.dart';
import 'package:vaster_resources/vaster_resources.dart';

void main() {
  group('ResourceQuota & ResourceTracker', () {
    test('tracks token usage and throws when quota exceeded', () {
      final tracker = ResourceTracker(
        quota: const ResourceQuota(maxTokenBudget: 100),
      );

      tracker.consumeTokens(50);
      expect(tracker.consumedTokens, equals(50));

      expect(() => tracker.consumeTokens(60),
          throwsA(isA<QuotaExceededException>()));
    });

    test('tracks tool call executions and throws when limit exceeded', () {
      final tracker = ResourceTracker(
        quota: const ResourceQuota(maxToolCallsPerTask: 2),
      );

      tracker.recordToolCall();
      tracker.recordToolCall();
      expect(tracker.toolCallCount, equals(2));

      expect(() => tracker.recordToolCall(),
          throwsA(isA<QuotaExceededException>()));
    });

    test('checks deadline expiration', () async {
      final tracker = ResourceTracker(
        quota: const ResourceQuota(timeDeadline: Duration(milliseconds: 50)),
      );

      await Future.delayed(const Duration(milliseconds: 70));
      expect(() => tracker.checkDeadline(),
          throwsA(isA<QuotaExceededException>()));
    });
  });
}
