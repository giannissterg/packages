# Changelog

## Unreleased

- Checkpoints carry the disk-mount table (`diskMounts`): a pre-suspension
  `MountFsOp`'s disk mount is re-established on resume instead of trapping
  (found by the first real-backend prove-it run; files survive restarts by
  nature, the mount TABLE is machine state).

## 0.4.0

- **BREAKING**: format v2 — everything machine-owned rides inside the
  continuation's `MachineSnapshot`; the checkpoint no longer enumerates
  machine state (toolset/handlers/quota fields removed). Message inboxes are
  captured and restored. Checkpoint-anywhere + round-trip-completeness
  enforcement tests.

## 0.3.0

- Initial release: `MachineCheckpoint` — a versioned, self-contained JSON
  capture of a suspended pipeline (program VBC, execution continuation,
  session histories, context heap, memory-mount files, and consumed
  quota/budget meters) with `capture` / `restoreRuntime` / `resume`.
  Composes `vaster_continuation` (the pure execution snapshot) with each
  subsystem's own snapshot surface; no subsystem knows what a checkpoint is.
