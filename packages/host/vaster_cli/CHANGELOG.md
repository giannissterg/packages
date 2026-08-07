# Changelog

## Unreleased

- Rule 11 V1: `registerCommand` returns the same-name command it
  displaced.

- **`vaster replay <envelope> [--diff]`** — agent regression testing as
  a first-class verb: re-execute a recorded run against its tape at
  zero tokens; a faithful replay consumes every recording and exits 0;
  any divergence (unmatched request OR unconsumed recordings) exits 1,
  and `--diff` renders the structured report — message-indexed,
  char-located, with before/after excerpts and informational context
  (system/cache-hint drift marked as such, since they are not part of
  the fingerprint).

- `vaster check` pairs fitted calibration with the bound (Rule 10.6 —
  the host owns the pairing): new `--backend` names the intended
  execution backend for profile lookup (falls back to a `--model`
  profile, then the heuristic), and the report says which estimate
  produced the bound. The prove-it loop closes: `--backend claude-cli`
  bounds release_scribe-shaped calls at $0.1146 where the measured
  reality was $0.1157 — within 1%, where the API-shaped bound was 2.2x
  low.

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
