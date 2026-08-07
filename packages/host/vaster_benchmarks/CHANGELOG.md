# Changelog

## Unreleased

- `agent_effects_once` (GAP-3a): the exactly-once claim inside an agent
  task — a re-dispatched task never re-executes its predecessor's tool
  effects. The measurable definition of agent reliability parity.

## 0.1.0

- The reliability benchmark set (REL-P5, gate 4's evidence): five
  benchmarks — two replaying real recorded backend traffic (claude-cli
  SDD run locked to 450,302 tokens / $0.825917 wire cost; llama-ffi
  local inference) and three injecting deterministic faults that prove
  the REL-P2/P3/P4 semantics (retry heals, fallback serves, effects
  execute once). CI runs the whole set at zero token cost via the sweep;
  `dart run vaster_benchmarks:export` emits the live-runnable `.vbc`
  artifacts for the protocol in `docs/RELIABILITY.md`.
