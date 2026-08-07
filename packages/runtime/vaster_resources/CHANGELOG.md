## Unreleased

- **BREAKING (Rule 11 V2)**: consumption returns running balances
  (`consumeTokens`/`consumeCost`/`recordToolCall`), `applyQuota` returns
  the quota it displaced, `restoreConsumed` echoes the restored
  snapshot, `checkDeadline` returns the time remaining (null when no
  deadline).

## 0.2.0

- Initial version.
