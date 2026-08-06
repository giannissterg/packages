# Test your agents like code

_Every transcript below is real, re-run against the tree it's committed
to. The fixture it uses is committed too — this document is
reproducible._

Agent behavior is notoriously untestable: real-model tests cost money
and flake; mocks test your mocks. Vaster's answer is **record once,
replay forever**: because a pipeline is a compiled artifact and every
model call flows through one seam, a single recorded run becomes a
deterministic regression test — and when behavior changes, the diff
tells you *what* changed, down to the character.

## 1. Record once

`story_lines`: four chained model turns over a pinned knowledge prefix,
run on a real local model (llama.cpp over FFI — free) and recorded:

```text
$ dart run vaster_playground:compile_replay_demo
compiled 8 instructions → artifacts/replay_demo/story_lines.vbc

$ vaster run artifacts/replay_demo/story_lines.vbc --backend llama \
    --model ~/models/stories15M-q4_0.gguf --record story_lines.replay.json
[record] 8 steps + 4 model calls → story_lines.replay.json
```

The envelope is self-contained: the compiled program, the step journal,
and the **model tape** — every request in full, every response with
measured usage (spec: [specs/REPLAY_ENVELOPE.md](specs/REPLAY_ENVELOPE.md)).
Commit it like any other fixture.

## 2. Replay forever — zero tokens

```text
$ vaster replay story_lines.replay.json
── VASTER REPLAY ───────────────────────────────────────
  program : story_lines (8 instructions)
  tape    : v2 · 4 recordings · llama-ffi:stories15M-q4_0
  status  : halted
✓ replay faithful: every recording consumed, zero tokens spent.
```

Faithful means *bit-for-bit behavioral equivalence*: the pipeline made
exactly the recorded requests, in a compatible order, and consumed every
recording. Both failure modes exit 1 — an unmatched request, **and** the
quiet one where the run completes but recordings go unconsumed (your
pipeline silently makes fewer calls than it used to).

As a CI test, the same thing is four lines of Dart — see the committed
example
[`story_lines_regression_test.dart`](../packages/host/vaster_playground/test/story_lines_regression_test.dart),
which runs in this repo's own sweep on every push.

## 3. When it breaks, see exactly what changed

Someone "improves" a prompt template — one word:

```text
$ vaster replay story_lines.replay.json --program edited/story_lines.vbc --diff
✗ Replay diverged at call #0: no recorded response matches this request.

call #0 diverged (vs recording [0]):
  ✗ message[1] (user) text diverges at char 33 (+9 chars):
    "… story facts, write the opening line of a story …"
  → "… story facts, write the dramatic opening line of…"
```

Message-indexed, char-located, before/after excerpts. The report also
distinguishes deltas that *cause* divergence (✗ — messages, tools,
response schema: the fingerprint inputs) from informational drift
(ℹ — system instruction, cache hints), and it is honest about its
limits: v1 recordings without full requests say "re-record for
message-level diffs"; identical content names an *order* divergence.

## What this catches that eval doesn't (and vice versa)

Replay regression testing catches **any change in what your pipeline
asks a model** — prompt edits, template interpolation changes, context
compilation drift, compiler changes, call-order changes — for free, at
CI speed, deterministically. It deliberately does not judge *output
quality* under a live model: that's `vaster eval`'s job (N live trials,
scored, with real metered cost). Use both: replay guards the machine's
half of the behavior; eval measures the model's half.

## The compounding

The same recorded envelope is also: a **time-travel debugging** session
(`vaster debug` — inspect any register, file, or context region as it
was at any step), and a **calibration fixture** (measured usage per
recorded request feeds the per-backend estimate profiles that make
`vaster check`'s cost bounds honest). Record once; three tools consume
it.
