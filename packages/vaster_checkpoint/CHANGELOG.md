# Changelog

## 0.3.0

- Initial release: `MachineCheckpoint` — a versioned, self-contained JSON
  capture of a suspended pipeline (program VBC, execution continuation,
  session histories, context heap, memory-mount files, and consumed
  quota/budget meters) with `capture` / `restoreRuntime` / `resume`.
  Composes `vaster_continuation` (the pure execution snapshot) with each
  subsystem's own snapshot surface; no subsystem knows what a checkpoint is.
