## Unreleased

- `ToolCallReplayedEvent` (REL-P4): the idempotency ledger replayed a
  recorded tool result instead of re-executing the call — a deduped side
  effect is observable, never silent.
- `ModelFallbackEvent` (REL-P3): one typed event per fallback-chain advance
  — `fromModel`, `toModel`, and the failure text that triggered it.

## 0.2.0

- Initial version.
