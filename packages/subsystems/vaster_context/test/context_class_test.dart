import 'package:test/test.dart';
import 'package:vaster_context/vaster_context.dart';
import 'package:vaster_model/vaster_model.dart';

void main() {
  group('BudgetShare', () {
    test('floor and ceiling combine tokens and fractions', () {
      const share = BudgetShare(minTokens: 500, minFraction: 0.1, maxTokens: 5000, maxFraction: 0.5);
      // window 10000: floor = max(500, 1000) = 1000; ceiling = min(5000, 5000)
      expect(share.floorFor(10000), equals(1000));
      expect(share.ceilingFor(10000), equals(5000));
      // window 2000: floor = max(500, 200) = 500; ceiling = min(5000, 1000)
      expect(share.floorFor(2000), equals(500));
      expect(share.ceilingFor(2000), equals(1000));
      expect(const BudgetShare().ceilingFor(1000), isNull);
    });

    test('validate catches inverted and out-of-range bounds', () {
      expect(const BudgetShare(minTokens: 10, maxTokens: 5).validate('x'), isNotEmpty);
      expect(const BudgetShare(minFraction: 1.5).validate('x'), isNotEmpty);
      expect(const BudgetShare(weight: -1).validate('x'), isNotEmpty);
      expect(const BudgetShare(minTokens: 5, maxTokens: 10).validate('x'), isEmpty);
    });
  });

  group('ContextClassTable', () {
    test('standard table is valid and band-ordered', () {
      expect(ContextClassTable.standard.validate(), isEmpty);
      final bands = ContextClassTable.standard.inBandOrder.map((c) => c.name).toList();
      expect(bands, equals(['system', 'tools', 'knowledge', 'general', 'history', 'scratch']));
    });

    test('resolve falls back to the default class for unknown ids', () {
      final table = ContextClassTable.standard;
      expect(table.resolve('knowledge').name, equals('knowledge'));
      expect(table.resolve(null).name, equals('general'));
      expect(table.resolve('no_such_class').name, equals('general'));
      expect(table.contains('no_such_class'), isFalse);
    });

    test('withOverrides replaces and extends; JSON round-trips', () {
      final table = ContextClassTable.standard.withOverrides([
        const ContextClass(
          name: 'knowledge',
          band: 20,
          share: BudgetShare(minFraction: 0.2),
          cacheStable: true,
        ),
        const ContextClass(name: 'domain_docs', band: 25, cacheStable: true),
      ]);

      expect(table.resolve('domain_docs').band, equals(25));
      expect(table.resolve('knowledge').share.minFraction, equals(0.2));

      final restored = ContextClassTable.fromJson(table.toJson());
      expect(restored.validate(), isEmpty);
      expect(restored.resolve('domain_docs').cacheStable, isTrue);
      expect(restored.resolve('knowledge').share.minFraction, equals(0.2));
      expect(restored.resolve('scratch').lifetime, equals(ContextLifetime.ephemeral));
      expect(restored.resolve('history').eviction, equals(EvictionPolicy.dropOldest));
    });

    test('totalReservedFor sums hard floors', () {
      final table = ContextClassTable.standard.withOverrides([
        const ContextClass(name: 'knowledge', band: 20, share: BudgetShare(minTokens: 3000)),
        const ContextClass(name: 'system', band: 0, share: BudgetShare(minFraction: 0.1)),
      ]);
      expect(table.totalReservedFor(10000), equals(3000 + 1000));
    });

    test('validate flags mismatched keys and missing default class', () {
      const bad = ContextClassTable(
        classes: {'a': ContextClass(name: 'b', band: 0)},
        defaultClassName: 'missing',
      );
      expect(bad.validate(), hasLength(2));
    });
  });

  group('ContextRegion policy inheritance', () {
    const highClass = ContextClass(
      name: 'important',
      band: 5,
      priority: ContextPriority.high,
      lifetime: ContextLifetime.persistent,
      compressibility: ContextCompressibility.summarize,
      pinnedByDefault: true,
    );

    test('null fields inherit from the class; explicit fields override', () {
      final inheriting = ContextRegion.text(id: 'r1', label: 'r1', role: Role.user, text: 'hello');
      expect(inheriting.effectivePriority(highClass), equals(ContextPriority.high));
      expect(inheriting.effectiveLifetime(highClass), equals(ContextLifetime.persistent));
      expect(inheriting.effectiveCompressibility(highClass), equals(ContextCompressibility.summarize));
      expect(inheriting.effectivePinned(highClass), isTrue);

      final overriding = ContextRegion.text(
        id: 'r2',
        label: 'r2',
        role: Role.user,
        text: 'hello',
        priority: ContextPriority.low,
        lifetime: ContextLifetime.ephemeral,
        compressibility: ContextCompressibility.none,
      );
      expect(overriding.effectivePriority(highClass), equals(ContextPriority.low));
      expect(overriding.effectiveLifetime(highClass), equals(ContextLifetime.ephemeral));
      expect(overriding.effectiveCompressibility(highClass), equals(ContextCompressibility.none));
    });

    test('legacy OrDefault views reproduce pre-class defaults', () {
      final region = ContextRegion.text(id: 'r', label: 'r', role: Role.user, text: 'x');
      expect(region.priorityOrDefault, equals(ContextPriority.medium));
      expect(region.lifetimeOrDefault, equals(ContextLifetime.session));
      expect(region.compressibilityOrDefault, equals(ContextCompressibility.none));
    });

    test('source-sync merge preserves heap-side classId and overrides', () {
      final heap = ContextHeap();
      heap.addRegion(ContextRegion.text(id: 'doc', label: 'doc', role: Role.user, text: 'v1'));
      // Operator assigns a class + pin on the heap side.
      heap.updateRegion('doc', (r) => r.copyWith(classId: 'knowledge', isPinned: true));

      // Source refresh with new content.
      heap.upsertFromSource(
        ContextRegion.text(id: 'doc', label: 'doc', role: Role.user, text: 'v2'),
        fingerprintOf: regionFingerprintOf,
      );

      final merged = heap.getRegion('doc')!;
      expect(regionContentOf(merged), equals('v2'));
      expect(merged.classId, equals('knowledge'));
      expect(merged.isPinned, isTrue);
      expect(merged.priority, isNull, reason: 'no override — still inherits');
    });
  });
}
