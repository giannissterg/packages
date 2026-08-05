# Changelog

## 0.4.0

- Initial release: `EvalHarness` — N hermetic trials per variant (fresh VM +
  runtime each, via a caller-owned vm factory; the harness depends on no
  engine), composable `Scorer`s (halted / contains / regex / function /
  allOf), and aggregated `EvalReport`s with success rate, mean score, and
  real metered tokens/cost/latency per trial. `vaster eval` CLI verb with
  `--trials`, `--contains` (repeatable), `--regex`, `--json`; exit 1 below
  100% success. Known limitation: programs with HITL gates pause rather
  than complete — eval targets gate-free programs (or gate-free slices) for
  now.
