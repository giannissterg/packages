# Changelog

## Unreleased

- `JsonComparator`/`JsonDivergence` — the normative deep-JSON frame
  comparator (ISA.md §Conformance procedure: mathematical number
  equality, exact key sets, first-divergence field paths) lives HERE,
  the journal/envelope package, as its one home. Consumed by the
  conformance suite's reference runner and the debugger's verified
  materialization.

## 0.5.0

- **BREAKING (C wave)**: `VasterExecutionRecorder.detach` returns the
  observer it RESTORED (symmetric with `attach`'s displaced observer),
  not the journal — the journal was always reachable via `journal`, the
  chain link is what only detach knows. `reset` returns frames dropped;
  `VasterExecutionJournal.clear` likewise.

- **BREAKING (Rule 11 V6)**: `VasterExecutionRecorder.attach` returns
  the observer it displaced; `detach` returns the journal it recorded.

- Rule 11 V2: `VasterExecutionJournal.recordStep` returns the recorded
  frame's step index — the handle seek/getFrameAt address it by.

- `RequestDiffer` + sealed `RequestDelta`/`DivergenceReport` — the
  structured answer to "what changed?": positional candidate alignment,
  first-divergence char offsets with excerpts, fingerprint-relevant vs
  informational deltas distinguished, v1 preview-only and order-only
  divergences named explicitly. `ReplayVasterModel.lastDivergence`
  retains the typed divergence across runtime trap boundaries.

- **Tape v2 + the envelope codec (spec: docs/specs/REPLAY_ENVELOPE.md).**
  Recordings now carry the full `ModelRequest` per entry (sealed
  `RecordedRequest`: `FullRecordedRequest` v2 / `PreviewOnlyRequest` v1 —
  consumers must handle old tapes explicitly); divergence is typed data
  (`TapeDivergenceException`: live request, call index, unconsumed
  candidates) instead of a `StateError` string. `ReplayEnvelopeCodec` is
  the one owner of envelope parse/encode — the debugger, `run
  --record/--replay`, and the calibration fitter all read through it.
  v1 tapes remain readable forever (fingerprints are the cross-version
  contract, spec'd; the paid fixture is the standing migration test).
## 0.3.0

- **BREAKING**: `DebugSession`/`DebugEnvelope`/`ReplayDivergence` moved to the
  new `vaster_debug` package; `vaster_replay` no longer depends on
  `vaster_vm`.

## 0.2.0

- Deterministic execution recording & replay: step journals, model I/O tapes,
  and envelope format.
