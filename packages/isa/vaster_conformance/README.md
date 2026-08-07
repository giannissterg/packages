# vaster_conformance

The ISA conformance suite (1.0 gate 2): golden vectors, the normative
comparator, and the Dart reference runner. The normative text lives in
[`docs/specs/ISA.md`](../../../docs/specs/ISA.md) — this README is the
practical contract for implementing a vaster runtime in another language.

## What conformance means

Your runtime executes a `VasterProgram` and reproduces, step for step, the
journal that the reference implementation recorded — with every model call
answered from the recorded tape. Pass every `core` vector and your runtime
executes vaster programs identically for everything that is not
host-dependent.

## Consuming a vector

Each vector is two sibling files in `vectors/`:

- `<name>.vector.json` — the manifest: conformance class, family, and the
  `expect` block (final status, step count, result value, trap pc, pending
  HITL request, exported VFS state).
- `<name>.replay.json` — a replay envelope
  ([spec](../../../docs/specs/REPLAY_ENVELOPE.md)): the embedded program,
  the step journal, and the model tape.

Procedure (normative details in ISA.md §Conformance procedure):

1. Load the envelope; decode the embedded `program`.
2. Execute with: every model resolution answered from the tape
   (fingerprint-FIFO matching — you must reproduce request fingerprints),
   unlimited budget/policy, an in-memory filesystem, no live backends.
3. Before each step N: your pc MUST equal `frames[N].pc`; cross-check the
   frame's `instruction.opcode` against the program.
4. After each step N: compare your registers against `frames[N].registers`
   by deep JSON equality (mathematical number equality; no string
   coercion), and your call stack against `frames[N].callStack`. Ignore
   `timestamp` and `modelOutput`.
5. After the last frame: check `expect` — status, result register, trap pc
   (message text is out of contract), pending-request subset, VFS exports.
6. Report the FIRST divergence as `{vectorName, stepIndex, fieldPath,
   expected, actual}` and stop.

The Dart reference runner (`lib/src/reference_runner.dart`) is the
executable definition of steps 3–6 — when prose and runner disagree, the
runner is right and the prose has a bug to fix.

## Regenerating vectors

```bash
dart run vaster_conformance:generate_vectors
```

Regeneration is byte-identical by construction (scripted models, epoch
timestamp sentinel) and CI-enforced — a toolchain change that alters any
vector must be committed deliberately with the regenerated files.

## Coverage gates

`dart test` here enforces: every core opcode is exercised by ≥1 vector,
every registered opcode is documented in ISA.md, all vectors pass the
reference runner, and regeneration is stable. Adding an opcode without a
vector and a doc entry fails the suite by design.
