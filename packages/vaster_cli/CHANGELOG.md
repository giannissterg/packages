# Changelog

## 0.4.0

- New `vaster check <program>` — static verification: binding dominance,
  worst-case cost bound (`--model`, `--max-cost` gating), and policy proofs
  (`--policy read-only|unlimited|<file>`), with `--json` output.

- New `vaster resume <checkpoint.json>` — continue a durably parked pipeline
  in a fresh VM on any backend (`--respond approve|reject|<text>`,
  `--trace`, `--checkpoint-dir` to re-park at the next gate).
- `vaster run --checkpoint-dir <dir>`: a human-interaction pause writes a
  self-contained checkpoint and exits (code 3) instead of holding the
  process hostage.
- Backend resolution shared between `run` and `resume`
  (`backend_resolver.dart`).

## 0.3.0

- `vaster` CLI: compile, run (record/replay/trace/events/cores), audit,
  disassemble, debug (time-travel), inspect, serve, doctor.
