# Getting started with Vaster — the 10-minute tour

Everything below runs on the **fake model backend**: free, offline,
deterministic. No API key, no spend. At the end you'll have compiled a
pipeline, proven things about it before running it, killed it mid-run at a
human gate, resumed it from JSON in a fresh process, and stepped backward
through a recorded execution.

Every command and output shown here is a real transcript, re-run against
the tree it's committed to.

## 0. Setup (one minute)

```bash
git clone https://github.com/giannissterg/packages.git vaster && cd vaster
dart pub get
dart pub global activate --source path packages/vaster_cli
```

The last line puts `vaster` on your PATH (via `~/.pub-cache/bin`). If you
prefer not to activate, every `vaster …` below also works as
`dart run vaster_cli:vaster_cli …` from the repo root.

## 1. Your first pipeline (library API)

```bash
dart run vaster_playground:example_01_hello_pipeline
```

```text
compiled 4 instructions (result binding: summary)
status : halted
summary: Vaster compiles pipelines to bytecode whose execution can suspend
to a checkpoint and resume in a fresh process.
```

Open [`example_01_hello_pipeline.dart`](../packages/vaster_playground/bin/example_01_hello_pipeline.dart)
— it's one page. The shape to internalize:

- A `Pipeline` is a declarative tree. `output: Binding('bullets')` binds a
  step's value; `${bullets}` (or a `Binding` inside a `Template`) consumes
  it later. The compiler rejects a read no step is guaranteed to write.
- `compile()` produces a flat, serializable instruction program — that
  artifact, not your Dart code, is what the runtime executes.
- After halt, the pipeline's declared result is at
  `state.registers[program.resultBinding]`.
- The model is a constructor argument. A scripted `FakeVasterModel` and a
  real backend are interchangeable.

## 2. Compile an artifact the CLI can own

Pipelines don't have to live and die inside one Dart process. Example 02
compiles a pipeline — one model step, a **human approval gate**, a
disk-mounted output file, a declared budget — and writes it to disk:

```bash
dart run vaster_playground:example_02_ship_artifact
```

```text
compiled 13 instructions → artifacts/examples/triage_note.vbc
```

That `.vbc` file is a complete program. Everything from here on uses only
the artifact.

## 3. Audit: what *could* this program do?

```bash
vaster audit artifacts/examples/triage_note.vbc
```

```text
Filesystem mounts:   /workspace → DISK artifacts/examples/workspace
File writes:         /workspace/TRIAGE.md
Human gates:         [PC:0005] file_ticket
Resource ceilings:   20000 tokens, $0.5
Decision surface:    (none — control flow is fully static)
```

No execution happened — this is read off the bytecode. Before running
anyone's pipeline (including your own from three weeks ago), you can see
every file it can touch, every tool it can call, every place the model
steers, and every point a human must approve.

## 4. Check: prove things before spending a token

```bash
vaster check artifacts/examples/triage_note.vbc --model claude-opus-5 --max-cost 0.5
```

```text
  program : triage_note (13 instructions)
  bound   : ≤1 model calls, ≤1053 tokens, ≤$0.0257
  findings: none — clean
```

A worst-case bound from control-flow analysis plus pricing tables:
`--max-cost` makes it a CI gate (nonzero exit on breach). Now the negative
proof — pretend our policy forbade file writes:

```bash
vaster check artifacts/examples/triage_note.vbc --policy read-only
```

```text
  policy  : read_only — 1 PROVEN VIOLATION(S), fully proven
  [error] policy_violation_proven: Instruction at pc 9 performs file:write
  on "/workspace/TRIAGE.md", which the declared policy denies — this WILL
  trap at runtime.                                              (exit 1)
```

The exact instruction, before execution, at zero cost.

> Honesty note: cost bounds model API-shaped calls. Agentic CLI backends
> (claude CLI, gemini CLI) do their own exploration per call and can
> exceed the static bound — the run-time `BudgetScope` is the enforced
> defense there. Measured and documented in [PROVE_IT.md](PROVE_IT.md).

## 5. Run until it needs a human — then let the process die

```bash
vaster run artifacts/examples/triage_note.vbc --backend fake \
    --checkpoint-dir artifacts/examples/ckpts
```

```text
── PARKED (durable) ────────────────────────────────────
  awaiting: File this triage note?
  checkpoint: artifacts/examples/ckpts/triage_note_file_ticket.ckpt.json
  resume: vaster resume artifacts/examples/ckpts/triage_note_file_ticket.ckpt.json --respond approve
```

Exit code **3**: the run is parked, not failed. The checkpoint is
self-contained JSON — program, registers, session transcripts, context,
mounts, spent meters. The process is gone; nothing is held in memory.

## 6. Resume in a fresh process

Days later, a different process, even a different machine:

```bash
vaster resume artifacts/examples/ckpts/triage_note_file_ticket.ckpt.json \
    --backend fake --respond approve
```

```text
── RESUME COMPLETE ────────────────────────────────────
  status : halted
  tokens : 119 total (0 this resume)
  output : filed
```

```bash
cat artifacts/examples/workspace/TRIAGE.md   # the approved artifact, on real disk
```

Meters continued from where they stood (the approve branch honestly cost
zero new tokens). `--respond reject` takes the other compiled branch.

## 7. Time-travel through a recorded run

Runs recorded with `vaster run --record <file>` (and replayed for free
with `--replay`) are also debuggable. The repo ships a recorded fixture
from a real paid Gemini run — step through it:

```bash
vaster debug packages/vaster_playground/test/fixtures/sdd_fidelity.replay.json \
    --script "seek 20; vfs /workspace; cat /workspace/spec.md"
```

```text
step 20/20  [0021] halt                 --- HALT ---
(vdb) vfs /workspace
  /workspace/spec.md  (1960 bytes)
  /workspace/plan.md  (11126 bytes)
  /workspace/review.md  (3543 bytes)
```

`seek 5; vfs /workspace` shows the filesystem *as it was* at step 5 —
files that didn't exist yet, don't. Drop `--script` for the interactive
`(vdb)` REPL (`help` lists `seek`, `regs`, `diff`, `cat`, `ctx`, …).

## Where to go next

- **Bounded agency**: `dart run vaster_playground:example_03_bounded_agency`
  — the model chooses a branch, but only among declared destinations, and
  the unchosen path provably never runs. Then re-run `vaster audit` on a
  program with `Decide` nodes to see its decision surface enumerated.
- **Real backends**: add `--backend claude-cli` (needs the `claude` CLI)
  or `--backend gemini` (needs `GEMINI_API_KEY`) to the same `run`/
  `resume` commands. Read [PROVE_IT.md](PROVE_IT.md) first — it is the
  same arc as this tour on real money, including what it cost.
- **Measure instead of vibe**: `vaster eval <prog> --trials 5 --contains
  <expected>` runs hermetic trials and reports success rate with real
  metered cost.
- **The full example catalog**:
  [packages/vaster_playground](../packages/vaster_playground) — fan-out,
  worker/critic loops, agent teams, the SDD workflow kit, RPC sidecars.
- **The constitution**: [rules.md](../rules.md) — the architectural law
  the codebase is held to. [ROADMAP.md](../ROADMAP.md) — where this is
  going and what 1.0 means.
