import 'package:test/test.dart';
import 'package:vaster_context/vaster_context.dart';
import 'package:vaster_model/vaster_model.dart';

void main() {
  group('ContextRegion & ContextHeap', () {
    test('ContextRegion text constructor estimates tokens', () {
      final region = ContextRegion.text(
        id: 'r1',
        label: 'User Query',
        role: Role.user,
        text: 'Hello Vaster runtime context!',
        priority: ContextPriority.high,
      );

      expect(region.id, equals('r1'));
      expect(region.priority, equals(ContextPriority.high));
      expect(region.estimatedTokens, greaterThan(0));
    });

    test('ContextHeap manages regions and calculates total tokens', () {
      final heap = ContextHeap();
      heap.addRegion(ContextRegion.text(
        id: 'sys',
        label: 'System Prompt',
        role: Role.system,
        text: 'System instructions',
        estimatedTokens: 20,
        priority: ContextPriority.critical,
      ));
      heap.addRegion(ContextRegion.text(
        id: 'usr',
        label: 'User Message',
        role: Role.user,
        text: 'User prompt',
        estimatedTokens: 10,
        priority: ContextPriority.medium,
      ));

      expect(heap.regions.length, equals(2));
      expect(heap.totalEstimatedTokens, equals(30));

      heap.clearNonCritical();
      expect(heap.regions.length, equals(1));
      expect(heap.regions.first.id, equals('sys'));
    });
  });

  group('TokenBudget & ContextSource', () {
    test('TokenBudget calculates available input budget', () {
      const budget = TokenBudget(
        maxContextTokens: 100000,
        reservedOutputTokens: 4000,
        reservedToolTokens: 1000,
      );
      expect(budget.availableInputBudget, equals(95000));
    });

    test('MemoryContextSource generates text regions', () {
      final source = MemoryContextSource(
        id: 'mem1',
        data: {'system': 'Be helpful.', 'user_pref': 'Dark mode'},
      );

      final regions = source.getRegions();
      expect(regions.length, equals(2));
      expect(regions.first.messages.first.role, equals(Role.system));
    });

    test('FileContextSource generates file region', () {
      final source = FileContextSource(
        id: 'f1',
        filePath: 'lib/main.dart',
        content: 'void main() {}',
      );

      final regions = source.getRegions();
      expect(regions.length, equals(1));
      expect(regions.first.label, contains('lib/main.dart'));
    });
  });
}
