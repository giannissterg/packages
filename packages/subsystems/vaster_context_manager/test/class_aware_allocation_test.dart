import 'package:test/test.dart';
import 'package:vaster_context/vaster_context.dart';
import 'package:vaster_context_manager/vaster_context_manager.dart';
import 'package:vaster_model/vaster_model.dart';

/// The context "linker": segmented, classful, deterministic.
void main() {
  ContextRegion region(
    String id, {
    String? classId,
    int tokens = 100,
    int order = 0,
    double utility = 1.0,
    ContextPriority? priority,
    bool pinned = false,
    Role role = Role.user,
    String? text,
  }) => ContextRegion.text(
    id: id,
    label: id,
    role: role,
    text: text ?? 'content of $id',
    estimatedTokens: tokens,
    classId: classId,
    order: order,
    utility: utility,
    priority: priority,
    isPinned: pinned,
  );

  // Window: 10000 - 0 - 0 = 10000, slack 1.0 for round-number assertions.
  const budget = TokenBudget(maxContextTokens: 10000, reservedOutputTokens: 0, reservedToolTokens: 0);

  ClassAwareAllocationStrategy strategyWith(ContextClassTable table) =>
      ClassAwareAllocationStrategy(classTable: table, allocationSlack: 1.0);

  group('ClassAwareAllocationStrategy', () {
    test('reservations are satisfied before weighted surplus', () {
      final table = ContextClassTable.standard.withOverrides([
        const ContextClass(
          name: 'knowledge',
          band: 20,
          share: BudgetShare(minTokens: 3000),
          cacheStable: true,
        ),
        const ContextClass(name: 'history', band: 30, share: BudgetShare(weight: 100)), // greedy competitor
      ]);

      final compiled = strategyWith(table).allocate(
        regions: [
          for (var i = 0; i < 8; i++) region('hist_$i', classId: 'history', tokens: 2000, order: i),
          region('know_a', classId: 'knowledge', tokens: 1500, order: 0),
          region('know_b', classId: 'knowledge', tokens: 1500, order: 1),
        ],
        budget: budget,
      );

      // Knowledge got its full 3000-token floor despite history's weight.
      expect(compiled.classUsage['knowledge']!.admittedTokens, equals(3000));
      expect(compiled.classUsage['history']!.admittedTokens, equals(6000));
      expect(compiled.totalEstimatedTokens, lessThanOrEqualTo(10000));
    });

    test('caps bound a class even with surplus available', () {
      final table = ContextClassTable.standard.withOverrides([
        const ContextClass(name: 'scratch', band: 90, share: BudgetShare(maxTokens: 1000)),
      ]);

      final compiled = strategyWith(table).allocate(
        regions: [for (var i = 0; i < 5; i++) region('s_$i', classId: 'scratch', tokens: 400)],
        budget: budget,
      );

      expect(compiled.classUsage['scratch']!.admittedTokens, lessThanOrEqualTo(1000));
      expect(compiled.evictedRegions, isNotEmpty);
    });

    test('PREFIX STABILITY: growing volatile pressure never changes a '
        'cache-stable band\'s layout', () {
      final table = ContextClassTable.standard.withOverrides([
        const ContextClass(
          name: 'knowledge',
          band: 20,
          share: BudgetShare(minTokens: 2000),
          cacheStable: true,
        ),
      ]);
      final strategy = strategyWith(table);

      final knowledge = [
        region('know_a', classId: 'knowledge', tokens: 800, order: 0),
        region('know_b', classId: 'knowledge', tokens: 700, order: 1),
        region('know_c', classId: 'knowledge', tokens: 500, order: 2),
      ];

      List<String> knowledgeLayout(int historyRegions) {
        final compiled = strategy.allocate(
          regions: [
            ...knowledge,
            for (var i = 0; i < historyRegions; i++)
              region('hist_$i', classId: 'history', tokens: 1500, order: i),
          ],
          budget: budget,
        );
        return compiled.includedRegions.where((r) => r.classId == 'knowledge').map((r) => r.id).toList();
      }

      final calm = knowledgeLayout(1); // no pressure
      final pressured = knowledgeLayout(20); // history wants 30k of 10k

      expect(calm, equals(['know_a', 'know_b', 'know_c']));
      expect(pressured, equals(calm), reason: 'the stable band must be a function of its own content only');
    });

    test('cache-stable classes shed from the tail only (prefix cut)', () {
      final table = ContextClassTable.standard.withOverrides([
        const ContextClass(
          name: 'knowledge',
          band: 20,
          share: BudgetShare(minTokens: 1200, maxTokens: 1200),
          cacheStable: true,
        ),
      ]);

      final compiled = strategyWith(table).allocate(
        regions: [
          region('know_a', classId: 'knowledge', tokens: 800, order: 0),
          region('know_b', classId: 'knowledge', tokens: 700, order: 1),
          // Small region AFTER a too-big one must NOT leapfrog it — that would
          // change the band's byte-prefix.
          region('know_c', classId: 'knowledge', tokens: 100, order: 2),
        ],
        budget: budget,
      );

      final ids = compiled.includedRegions.where((r) => r.classId == 'knowledge').map((r) => r.id);
      expect(ids, equals(['know_a']), reason: 'tail cut at know_b; know_c must not be reordered in');
    });

    test('repeat compiles are byte-identical (deterministic layout)', () {
      final regions = [
        region('z', classId: 'history', tokens: 100, order: 5),
        region('a', classId: 'history', tokens: 100, order: 5),
        region('m', classId: 'knowledge', tokens: 100),
        region('k', classId: 'knowledge', tokens: 100),
        region('sys', classId: 'system', role: Role.system, text: 'RULES'),
      ];
      final strategy = strategyWith(ContextClassTable.standard);

      final first = strategy.allocate(regions: regions, budget: budget);
      final second = strategy.allocate(regions: regions.reversed.toList(), budget: budget);

      expect(
        first.includedRegions.map((r) => r.id).toList(),
        equals(second.includedRegions.map((r) => r.id).toList()),
        reason: 'heap insertion order must not affect layout',
      );
      // Bands: knowledge(20) < history(30); ties break by id.
      expect(first.includedRegions.map((r) => r.id).toList(), equals(['sys', 'k', 'm', 'a', 'z']));
    });

    test('dropOldest sheds the oldest members under pressure', () {
      final table = ContextClassTable.standard.withOverrides([
        const ContextClass(
          name: 'history',
          band: 30,
          share: BudgetShare(maxTokens: 3000),
          eviction: EvictionPolicy.dropOldest,
        ),
      ]);

      final compiled = strategyWith(table).allocate(
        regions: [for (var i = 0; i < 5; i++) region('hist_$i', classId: 'history', tokens: 1000, order: i)],
        budget: budget,
      );

      expect(
        compiled.includedRegions.map((r) => r.id),
        equals(['hist_2', 'hist_3', 'hist_4']),
        reason: 'newest survive; layout stays chronological',
      );
      expect(compiled.evictedRegions.map((r) => r.id), containsAll(['hist_0', 'hist_1']));
    });

    test('multiple system regions concatenate in layout order', () {
      final compiled = strategyWith(ContextClassTable.standard).allocate(
        regions: [
          region('sys_b', classId: 'system', role: Role.system, text: 'Second rule.', order: 1),
          region('sys_a', classId: 'system', role: Role.system, text: 'First rule.', order: 0),
          region('chat', classId: 'history', text: 'hello'),
        ],
        budget: budget,
      );

      expect(
        (compiled.systemInstruction!.parts.first as TextPart).text,
        equals('First rule.\n\nSecond rule.'),
      );
      expect(compiled.messages, hasLength(1), reason: 'system content never leaks into messages');
    });

    test('unevictable overflow is a hard error naming the classes', () {
      expect(
        () => strategyWith(ContextClassTable.standard).allocate(
          regions: [region('sys', classId: 'system', role: Role.system, tokens: 20000)],
          budget: budget,
        ),
        throwsA(isA<ContextOverflowError>().having((e) => e.offendingClasses, 'classes', contains('system'))),
      );
    });

    test('classless regions resolve to the default class', () {
      final compiled = strategyWith(ContextClassTable.standard)
          .allocate(regions: [region('plain')], budget: budget);
      expect(compiled.classUsage.keys, contains('general'));
      expect(compiled.classUsage['general']!.admittedRegions, equals(1));
    });
  });
}
