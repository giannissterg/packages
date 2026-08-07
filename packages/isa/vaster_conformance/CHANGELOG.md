# Changelog

## Unreleased

- `JsonComparator`/`JsonDivergence` moved to `vaster_replay` (their one
  home — the debugger consumes them too and must never depend on this
  engine-carrying package); re-exported here unchanged.

- **The ISA conformance suite (1.0 gate 2).** Fifteen golden vectors
  (replay envelopes + expectation manifests) covering all 42 core opcodes;
  the normative deep-JSON comparator (mathematical number equality, no
  string coercion); the Dart reference runner — the executable definition
  of the comparison rules (pc-before-step, opcode cross-check, post-step
  register equality, timestamp excluded, first-divergence reporting); a
  deterministic generator (epoch timestamp sentinel, scripted models,
  byte-stable regeneration, CI-enforced); and coverage gates: every core
  opcode needs a vector, every registered opcode needs its
  `docs/specs/ISA.md` entry — adding an opcode without both fails the
  suite by design. Sandbox execution and disk mounts are capability
  classes with documented host-dependence reasons.
