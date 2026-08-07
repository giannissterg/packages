## Unreleased

- **A1 — the guarded tool-turn pipeline.** `ToolCallGate` (with
  `NoopToolCallGate`, `CompositeToolCallGate` — a LIST of gates
  encapsulated as a gate — and `ToolCallGateBinding`), plus `ToolTurn` /
  `ToolTurnOutcome` / `ToolTurnRunner`: the batch of calls a model emits
  in one turn is a first-class type owning the provider batching rule,
  the sealed per-call `ExecutedCall`/`ReplayedCall` fates, and the
  executed-vs-replayed counts. `ToolTurnConcurrency` declares sequential
  (ISA) vs parallel (agent) execution. `EffectRegion.isaLoop` gives the
  runtime loop a region so both loops share ONE key grammar.

- `ToolEffectRecorder` contract (GAP-3a): sealed `ToolEffectClaim`
  (`Replay`/`Slot`/`Inert`), `EffectRegion` value type riding task
  metadata, `commit` echoing the committed result (Rule 11), the
  canonical `NoopToolEffectRecorder`, and `ToolEffectRecorderBinding`
  whose `bind` returns the displaced recorder. Pure tool domain — no
  ISA, runtime, or agent knowledge.

## 0.2.0

- Initial version.
