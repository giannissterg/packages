import 'package:test/test.dart';
import 'package:vaster_budget/vaster_budget.dart';

void main() {
  group('ExecutionBudget', () {
    test('tracks consumption of duration, tokens, and cost', () {
      final budget = ExecutionBudget(
        maxDuration: const Duration(minutes: 5),
        maxTokens: 1000,
        maxCost: 2.50,
      );

      expect(budget.isExpired, isFalse);
      expect(budget.remainingDuration, equals(const Duration(minutes: 5)));
      expect(budget.remainingTokens, equals(1000));
      expect(budget.remainingCost, equals(2.50));

      budget.consumeTime(const Duration(minutes: 2));
      budget.consumeTokens(400);
      budget.consumeCost(1.00);

      expect(budget.remainingDuration, equals(const Duration(minutes: 3)));
      expect(budget.remainingTokens, equals(600));
      expect(budget.remainingCost, equals(1.50));
      expect(budget.isExpired, isFalse);

      budget.consumeTokens(500);
      expect(budget.remainingTokens, equals(100));

      budget.consumeTokens(200);
      expect(budget.remainingTokens, equals(0));
      expect(budget.isExpired, isTrue);
    });

    test('enforces hierarchical child budget limits bounded by parent remaining capacity', () {
      final parent = ExecutionBudget(
        maxDuration: const Duration(minutes: 10),
        maxTokens: 5000,
        maxCost: 10.0,
      );

      parent.consumeTime(const Duration(minutes: 4)); // 6 mins remaining
      parent.consumeTokens(2000); // 3000 tokens remaining
      parent.consumeCost(4.0); // 6.0 cost remaining

      // Child requests 15 mins, 4000 tokens, 8.0 cost.
      // Must be capped by parent remaining (6 mins, 3000 tokens, 6.0 cost).
      final child = parent.createChildBudget(
        maxDuration: const Duration(minutes: 15),
        maxTokens: 4000,
        maxCost: 8.0,
      );

      expect(child.maxDuration, equals(const Duration(minutes: 6)));
      expect(child.maxTokens, equals(3000));
      expect(child.maxCost, equals(6.0));
    });

    test('detects point-in-time deadline expiration', () {
      final deadline = DateTime.now().subtract(const Duration(seconds: 1));
      final budget = ExecutionBudget(deadline: deadline);

      expect(budget.isExpired, isTrue);
    });
  });
}
