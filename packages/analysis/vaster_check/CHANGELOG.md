# Changelog

## Unreleased

- `mostExpensiveSelectableModel` also scans `CreateAgentOp` descriptor
  chains (GAP-3b) — a pricey member hiding as an agent fallback rates
  the bound.
- With no caller-supplied rated model, `ProgramChecker` derives one: the
  most expensive model the program can select, fallback-chain members
  included (`mostExpensiveSelectableModel`). A chain whose pricey member
  hides behind a cheap primary is priced at the pricey member's rate —
  the analyzer's docs promised this rating discipline; now it is automatic.

- Cost bounds compose the estimation seam: `CostAnalyzer`/
  `ProgramChecker` accept a `TokenEstimator` (canonical heuristic by
  default — byte-identical bounds) and a `callOverheadFactor` for
  backends whose harness works beyond the visible prompt. The analyzer
  knows the seam, never the profiles — hosts pair them.

## 0.3.0

- Initial release: `ProgramChecker` — static verification over the ISA
  control-flow graph. Definite assignment (binding dominance: every read
  dominated by a write on every path), worst-case cost bounds (loop trip
  counts recognized from the compiler's canonical guard shape × prompt
  estimates × the pricing catalog, honest `unbounded` when a back-edge has
  no recognizable bound), and policy proofs (statically denied resources are
  proven violations; interpolated resources are unprovable warnings, never
  assumed safe). Sealed `CheckFinding` hierarchy; `vaster check` CLI verb
  with `--policy`, `--model`, and `--max-cost` gating.
