# Changelog

## 0.2.0

- Initial release: `ModelCallMeter` — the single metering pipeline for one
  model call (cost resolution via `PricingCatalog`, at most one
  `ModelUsageEvent`, then every registered `UsageSink` charged once).
- `UsageSink` with `BudgetSink` (`ExecutionBudget`) and `TrackerSink`
  (`ResourceTracker`) adapters; `TrackerSink(chargeTokens: false)` supports
  cost-only charging when the caller's own loop already charges tokens to the
  same tracker.
