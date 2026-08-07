# Changelog

## Unreleased

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
