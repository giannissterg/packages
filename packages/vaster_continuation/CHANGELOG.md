# Changelog

## 0.4.0

- **BREAKING**: `VasterContinuation` v2 = identity + `MachineSnapshot`. The
  five hand-copied runtime projections and `StackFrame` are gone; v1 payloads
  are rejected (they are missing machine state by construction).

## 0.3.0

- Serializable execution snapshots (v1 era).
