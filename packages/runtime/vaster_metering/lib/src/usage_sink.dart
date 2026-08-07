import 'package:vaster_budget/vaster_budget.dart';
import 'package:vaster_resources/vaster_resources.dart';

/// A meter that absorbs one model call's tokens and monetary cost.
///
/// Sinks are the variable part of a [ModelCallMeter]: the host budget, the
/// program quota tracker, and the VM resource tracker all count the same call
/// once each, by design (triple-meter layering). Implementations may throw
/// (quota trips) — the meter charges sinks in order and lets the trip
/// propagate to the call site that owns error handling.
abstract interface class UsageSink {
  /// Absorbs [tokens] and returns the sink's new consumed-token total
  /// (Rule 11 — the running balance).
  int addTokens(int tokens);

  /// Absorbs [costUsd] and returns the sink's new consumed-cost total.
  double addCost(double costUsd);
}

/// Charges an [ExecutionBudget] (host-level capacity).
final class BudgetSink implements UsageSink {
  final ExecutionBudget budget;

  const BudgetSink(this.budget);

  @override
  int addTokens(int tokens) => budget.consumeTokens(tokens);

  @override
  double addCost(double costUsd) => budget.consumeCost(costUsd);
}

/// Charges a [ResourceTracker] (VM- or program-level quota).
///
/// [chargeTokens] exists for call sites whose own loop already charges tokens
/// to the same tracker (the agent tool loop charges its shared tracker for
/// quota enforcement) — the sink then adds only what the loop cannot: cost.
final class TrackerSink implements UsageSink {
  final ResourceTracker tracker;
  final bool chargeTokens;

  const TrackerSink(this.tracker, {this.chargeTokens = true});

  @override
  int addTokens(int tokens) {
    if (chargeTokens) return tracker.consumeTokens(tokens);
    return tracker.consumedTokens;
  }

  @override
  double addCost(double costUsd) => tracker.consumeCost(costUsd);
}
