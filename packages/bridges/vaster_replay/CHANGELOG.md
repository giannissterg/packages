# Changelog

## Unreleased

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
