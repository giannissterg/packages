# Changelog

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
