# Changelog

## Unreleased

- `KvPrewarmer` delegates to `ContextMmu` (PV-P4): the page table owns
  hit/fault/invalidation — the prewarmer had been a hand-rolled copy of
  the bind loop minus invalidation. Park output now reports real
  `MmuStats`: regions materialized (with tokens), page hits ("already
  warm"), and stale mappings evicted.

- `vaster serve` decouples backend from transport: `--backend gemini|
  claude|claude-api|llama` × `--transport socket|shm` in any pairing —
  llama can be served over the Unix socket, and any backend over
  shared-memory rings (KV frame reuse needs a backend with a KV
  controller). The previous `--backend llama` implied rings; use
  `--backend llama --transport shm` now.

- New `vaster eval <program>` — N-trial evaluation with success rate, mean
  score, and real metered cost per trial (`--trials`, `--contains`,
  `--regex`, `--json`).

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
