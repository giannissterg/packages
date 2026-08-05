import 'package:test/test.dart';
import 'package:vaster_budget/vaster_budget.dart';
import 'package:vaster_events/vaster_events.dart';
import 'package:vaster_metering/vaster_metering.dart';
import 'package:vaster_model/vaster_model.dart';
import 'package:vaster_pricing/vaster_pricing.dart';
import 'package:vaster_resources/vaster_resources.dart';

void main() {
  const measured = UsageMetadata(
    promptTokenCount: 1000,
    candidatesTokenCount: 200,
    totalTokenCount: 1200,
    source: UsageSource.measured,
  );

  group('ModelCallMeter', () {
    test('charges every sink once with tokens and resolved cost', () {
      final budget = ExecutionBudget.unlimited();
      final tracker = ResourceTracker(quota: ResourceQuota.unlimited);
      final meter = ModelCallMeter(
        pricingCatalog: PricingCatalog.builtin,
        sinks: [BudgetSink(budget), TrackerSink(tracker)],
      );

      final cost = meter.charge(
        usage: measured,
        modelName: 'claude-sonnet-5',
        callSite: 'vm_prompt',
      );

      expect(budget.consumedTokens, equals(1200));
      expect(tracker.consumedTokens, equals(1200));
      expect(cost, isNotNull);
      expect(budget.consumedCost, equals(cost));
      expect(tracker.consumedCost, equals(cost));
    });

    test('wire-reported cost wins over the catalog', () {
      final budget = ExecutionBudget.unlimited();
      final meter = ModelCallMeter(
        pricingCatalog: PricingCatalog.builtin,
        sinks: [BudgetSink(budget)],
      );

      const wireUsage = UsageMetadata(
        promptTokenCount: 1000,
        candidatesTokenCount: 200,
        totalTokenCount: 1200,
        costUsd: 0.42,
        source: UsageSource.measured,
      );
      final cost = meter.charge(
        usage: wireUsage,
        modelName: 'claude-sonnet-5',
        callSite: 'vm_prompt',
      );

      expect(cost, equals(0.42));
      expect(budget.consumedCost, equals(0.42));
    });

    test('unpriceable model charges tokens but no cost', () {
      final budget = ExecutionBudget.unlimited();
      final meter = ModelCallMeter(
        pricingCatalog: PricingCatalog.empty,
        sinks: [BudgetSink(budget)],
      );

      final cost = meter.charge(
        usage: measured,
        modelName: 'mystery-model',
        callSite: 'vm_prompt',
      );

      expect(cost, isNull);
      expect(budget.consumedTokens, equals(1200));
      expect(budget.consumedCost, equals(0.0));
    });

    test('publishes exactly one ModelUsageEvent, before charging', () async {
      final bus = BasicEventBus();
      final events = <ModelUsageEvent>[];
      bus.on<ModelUsageEvent>().listen(events.add);

      // A quota tight enough to trip on this call: the event must still
      // arrive because emission precedes charging.
      final tracker = ResourceTracker(
          quota: const ResourceQuota(maxTokenBudget: 10));
      final meter = ModelCallMeter(
        pricingCatalog: PricingCatalog.empty,
        sinks: [TrackerSink(tracker)],
        eventBus: bus,
      );

      expect(
        () => meter.charge(
            usage: measured, modelName: 'm', callSite: 'agent_turn'),
        throwsA(isA<QuotaExceededException>()),
      );
      await Future<void>.delayed(Duration.zero);
      expect(events, hasLength(1));
      expect(events.single.callSite, equals('agent_turn'));
      expect(events.single.totalTokenCount, equals(1200));
      expect(events.single.estimated, isFalse);
    });

    test('charge-only meter (null bus) emits nothing', () {
      final meter = ModelCallMeter(
        pricingCatalog: PricingCatalog.empty,
        sinks: const [],
      );
      final cost = meter.charge(
          usage: measured, modelName: 'm', callSite: 'vm_prompt');
      expect(cost, isNull);
    });

    test('cost-only TrackerSink skips tokens but charges cost', () {
      final tracker = ResourceTracker(quota: ResourceQuota.unlimited);
      final meter = ModelCallMeter(
        pricingCatalog: PricingCatalog.builtin,
        sinks: [TrackerSink(tracker, chargeTokens: false)],
      );

      meter.charge(
        usage: measured,
        modelName: 'claude-sonnet-5',
        callSite: 'agent_turn',
      );

      expect(tracker.consumedTokens, equals(0));
      expect(tracker.consumedCost, greaterThan(0));
    });
  });
}
