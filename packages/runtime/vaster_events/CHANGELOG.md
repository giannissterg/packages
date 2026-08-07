## Unreleased

- **BREAKING (Rule 11 V7)**: `publish` returns the event's id — the
  correlation handle. Publish is NOT a sanctioned sink.

- **BREAKING (Rule 11 V6)**: `RuntimeEventBus.close` returns whether
  this call closed it (idempotence observable).

- `AgentTaskReplayedEvent` (GAP-2): the idempotency ledger replayed a
  recorded agent-task outcome instead of re-dispatching — the replay's
  usage is not re-charged.
- `ToolCallReplayedEvent` (REL-P4): the idempotency ledger replayed a
  recorded tool result instead of re-executing the call — a deduped side
  effect is observable, never silent.
- `ModelFallbackEvent` (REL-P3): one typed event per fallback-chain advance
  — `fromModel`, `toModel`, and the failure text that triggered it.

## 0.2.0

- Initial version.
