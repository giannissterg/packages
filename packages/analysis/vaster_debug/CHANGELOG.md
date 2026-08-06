# Changelog

## 0.2.0

- Initial release: `DebugSession`, `DebugEnvelope`, `ReplayDivergence`, and
  `ContextStateView` extracted from `vaster_replay` (architectural review):
  recording (replay) and interactive debugging (this package) are separate
  concerns, and the split lets `vaster_replay` shed its `vaster_vm`
  dependency.
