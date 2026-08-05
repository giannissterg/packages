import 'package:vaster_events/vaster_events.dart';
import 'package:vaster_model/vaster_model.dart';
import 'package:vaster_pricing/vaster_pricing.dart';

import 'usage_sink.dart';

/// The single metering pipeline for one model call.
///
/// `charge` performs, in order:
/// 1. **Cost resolution** — wire-reported `costUsd` wins, else the pricing
///    catalog rates the model, else cost is honestly unknown (null) and no
///    cost is charged anywhere.
/// 2. **Telemetry** — at most one [ModelUsageEvent], published *before*
///    charging so the usage is observable even when a quota trips. A null
///    [eventBus] makes this a charge-only meter: per the one-owner emission
///    rule, only the component that owns the model call emits, and layered
///    meters (host budget, program quota) count silently.
/// 3. **Charging** — every [UsageSink] absorbs the call's tokens and, when
///    known, its cost. Sinks may throw (quota trips propagate to the caller).
///
/// Estimation stays at the call site: the caller passes final usage (measured
/// or a labeled estimate) because only it knows the inputs an estimate needs.
/// When the usage is estimated, any catalog-computed cost is an estimate too —
/// still charged, because estimated work is not free work.
final class ModelCallMeter {
  final PricingCatalog pricingCatalog;
  final List<UsageSink> sinks;

  /// Emission channel — null for charge-only meters (one-owner rule).
  final RuntimeEventBus? eventBus;

  int _seq = 0;

  ModelCallMeter({
    required this.pricingCatalog,
    required this.sinks,
    this.eventBus,
  });

  /// Meters one call and returns its resolved cost (null when unpriceable).
  ///
  /// [callSite] names the owning funnel in telemetry — e.g. `vm_prompt`,
  /// `agent_turn`, `context_compression`.
  double? charge({
    required UsageMetadata usage,
    required String modelName,
    required String callSite,
  }) {
    final cost = pricingCatalog.resolveCostUsd(usage, modelName);
    eventBus?.publish(ModelUsageEvent(
      eventId: 'evt_usage_${callSite}_${_seq++}',
      modelName: modelName,
      callSite: callSite,
      promptTokenCount: usage.promptTokenCount,
      candidatesTokenCount: usage.candidatesTokenCount,
      totalTokenCount: usage.totalTokenCount,
      costUsd: cost,
      estimated: usage.source == UsageSource.estimated,
      usage: usage.toJson(),
    ));
    for (final sink in sinks) {
      sink.addTokens(usage.totalTokenCount);
      if (cost != null) sink.addCost(cost);
    }
    return cost;
  }
}
