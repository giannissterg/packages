# Changelog

## Unreleased

- Disk-mounted recordings DEGRADE to the journal tier instead of
  refusing to load: `DebugSession.load` never throws for them anymore.
  The new required sealed `DebugSession.materialization`
  (`MaterializationAvailable` / `MaterializationRefused(reason)`) is
  resolved once at load; `materialize()` — and with it every
  vfs/cat/ctx view, checkpoint export, and `--resume-at` — enforces it
  with the carried reason. Journal views (cursor, registers, deltas,
  call stacks, tape) work for every recording, including the
  external-codebase planning runs that surfaced this.

## 0.5.0

- **TT-P4**: `DebugSession.materializedMachine()` returns a
  `MaterializedMachine` — the runtime plus the `SnapshotHost` facet of
  the verified replay VM at the cursor, exactly what a checkpoint
  capture takes and never the master interface. Hosts compose live
  resume from it (`vaster debug --resume-at`); the debugger itself gains
  no checkpoint dependency.

- **BREAKING (B1, Rule 10.6)**: `DebugSession.load` requires a
  `vmFactory` — hosts own composition; this package no longer depends on
  the engine in production (`vaster_vm` is dev-only, matching
  `vaster_eval`'s pattern). The `vaster debug` CLI supplies the
  bootstrap.

## 0.2.0

- Initial release: `DebugSession`, `DebugEnvelope`, `ReplayDivergence`, and
  `ContextStateView` extracted from `vaster_replay` (architectural review):
  recording (replay) and interactive debugging (this package) are separate
  concerns, and the split lets `vaster_replay` shed its `vaster_vm`
  dependency.
