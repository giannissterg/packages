## Unreleased

- **BREAKING (R wave)**: `restoreConsumed` returns the named
  `ConsumptionSnapshot` (a Snapshot, not a Report — it echoes state).

- C wave: doc repair — `restoreConsumed` no longer wears
  `recordToolCall`'s stale first line (it claimed to increment a counter
  and enforce a quota, doing neither); `applyQuota`'s duplicate
  paragraph merged.

- **BREAKING (Rule 11 V2)**: consumption returns running balances
  (`consumeTokens`/`consumeCost`/`recordToolCall`), `applyQuota` returns
  the quota it displaced, `restoreConsumed` echoes the restored
  snapshot, `checkDeadline` returns the time remaining (null when no
  deadline).

## 0.2.0

- Initial version.
