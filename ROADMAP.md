# Vaster Roadmap

_Last updated: 2026-08-06, after the zero-copy + prefix-validation +
calibration arc._

## Where we are

The kernel is in place, honest, and now battle-tested:

- **Full pipeline**: declarative Flutter-style AST (typed `Binding`/`Template`/`Cond`,
  scope-provided defaults) → compiler → serializable ISA (VBC binary v2) →
  fetch-decode-dispatch runtime → VM subsystems, with `vaster_vm_api` breaking
  the last dependency cycle.
- **Token & cost fidelity**: every meter charges real wire-reported numbers
  (cache read/write breakdowns, thoughts, wire cost), estimates are centralized
  and labeled, and `ModelCallMeter` is the single metering pipeline — agent
  turns and context compression included. Validated by a paid recording
  (450,302 tokens / $0.825917, 87.9% cache reads).
- **Context as memory**: context classes with budget shares, eviction policy,
  and prefix-stability (`cacheStable`) invariants; class-aware linker.
- **Determinism**: recording/replay envelopes, fingerprinted model tapes, a
  committed CI fixture, and a two-tier time-travel debugger (`vaster debug`).
- **Stress-proven**: the launch-war-room suite drives every subsystem in one
  program across three assertion layers (static, dataflow, accounting) plus
  adversarial waves — including a security lock on single-pass interpolation
  and loud replay-divergence failure.
- **Actors + sealed data**: per-agent mailbox serialization (one session, one
  transcript, one task at a time), sealed `AgentLifecycle` and
  `ExtractOutcome` — failure shapes are data, not silence.
- **Zero-copy KV state, validated**: real llama.cpp inference over dart:ffi;
  KV state crosses process boundaries as spec'd binary images
  (docs/specs/KV_STATE_IMAGE.md — the first frozen format) with
  token-exact prefix validation and producer-identity tags; a parked
  pipeline resumes warm ("105 of 381 prompt tokens restored — never
  re-decoded"). The validation's first live run caught a real VM bug
  (sessionless prompts dropped pinned context — fixed, contract'd).
- **Calibrated honesty**: fitted per-backend estimate profiles with
  provenance and sample counts (vaster_calibration); `vaster check
  --backend claude-cli` bounds the prove-it workflow at $0.1146 vs its
  measured $0.1157 — within 1% where the old bound was 2.2x low.
- **703 tests green**, analyzer clean, 64 workspace packages.

## Evolution threads (the compounding order)

1. **Lock in** — v0.3.0 tag, CI, rules.md codification. Everything after is
   safer because of it.
2. **Durable execution** — ✅ delivered 2026-08-06: `vaster_checkpoint` +
   `vaster_machine_state` (componentized machine, checkpoint-anywhere
   enforcement), `vaster run --checkpoint-dir`, `vaster resume`; the
   war-room pipeline dies at its gate and launches from JSON in a fresh VM,
   live or tape-driven.
3. **`vaster check`** — ✅ delivered 2026-08-06: `vaster_check` package +
   CLI verb. Definite assignment over the CFG, worst-case cost bounds
   (loop-recognized, honest about unbounded), policy proofs
   (proven-violation vs unprovable-dynamic), `--max-cost` CI gating; the
   compiled war room checks clean with a finite bound.
4. **Zero-copy completion** — ✅ delivered 2026-08-06 (ZC-P0..P6, FFI
   architecture): `vaster_llama_ffi` — in-process llama.cpp over
   `dart:ffi`, KV state moving engine → shared frame pages → engine
   (`--backend llama`, `serve --backend llama` over rings, park-time
   kv-prewarm, warm `vaster resume` that never re-decodes the pinned
   prefix). Claim scoped and evidenced in docs/ZERO_COPY.md; transport
   honesty enforced (fake-success stub removed, two hidden bugs fixed).
   Cache-aware context *planning* (goal C) remains separate; the
   ContextMmu token-exact validation is its first step.
5. **Illegal states unrepresentable** — sealed `TaskOutcome`, typed `Schema`
   DSL, mailbox/inbox unification, supervisor restart policies
   (`MachinePhase` ✅ delivered).

## The pivot (assessed 2026-08-06)

Every remaining weakness is about **evidence and outside contact**, not
architecture. The machine is proven *correct*; it is not yet proven
*useful to anyone else*. Candid gaps as of 2026-08-06: no outside users
(not on pub.dev — gate 3 untouched); reliability semantics undeclared
(thread D/5 — real backends fail in kind, we mostly trap); most validation
still fake-model plus small-model llama runs and two paid recordings; the
portability claim has one spec + golden fixture (KV State Image) but no
ISA spec or second runtime; adversarial surface lightly probed; hosted
cache breakpoint budgeting unmodeled (goal C); claude-cli calibration is
n=1.

Outward order of attack:
1. v0.4.0 tag (✅ when this lands).
2. **The "prove it" milestone**: one genuinely useful workflow end-to-end on
   claude-cli for real — checked, run with durable parking, approved via
   `vaster resume` from a separate invocation, recorded, reported.
3. Eval harness MVP — ✅ delivered 2026-08-06: `vaster_eval` + `vaster eval`
   (hermetic N-trial runs, composable scorers, success rates with real
   metered cost).
4. Approachability — ✅ delivered 2026-08-06: honest README (claims match
   the machine, status section with candid limits), `docs/GETTING_STARTED.md`
   (the 10-minute tour, every command a verified transcript: compile →
   audit → check + negative proof → park at exit 3 → resume → time-travel
   debug), curated playground on-ramp (`example_01..03`) + real catalog
   README. pub.dev still waits for the surface to stabilize.
5. Then threads 4/5 by appetite — the real-model milestone will likely make
   the reliability campaign urgent on its own.

---

## Next improvements (near-term, concrete)

Ordered roughly by value-for-effort. Each is a self-contained sprint or less.

### 1. Release v0.3.0
Four of the five AR phases are breaking (`vaster_vm_api` extraction, required
ownership params, interface promotion, package moves). Roll the `Unreleased`
CHANGELOG sections into 0.3.0, bump pubspecs, tag. Cheap, and it puts a stake
in the ground before the next breaking wave.

### 2. CI pipeline — ✅ delivered (lock-in), hardened 2026-08-06
`.github/workflows/ci.yml`: `dart analyze --fatal-infos packages` + the
full sweep via `tool/test_sweep.sh` (one owner, shared with local runs).
Per-package invocation is load-bearing — it honors each package's
`dart_test.yaml` (the llama suites' concurrency guard, tags), which a
root-level mega-invocation silently didn't. Machine-gated suites degrade
honestly (llama self-skips without GGUF+libllama; gemini CLI integration
is opt-in via `VASTER_GEMINI_CLI_TESTS=1` — auth-gated gemini hangs
headless, so presence-detection alone stalled any machine that had it).
The sweep carries the fixture replay and every architectural guard test
(see docs/ARCHITECTURE.md's enforcement table).

### 3. Metering follow-ups
- `DispatchParallelTasksOp` does not forward `responseSchema`/`cacheHints`
  per dispatch the way `DispatchAgentTaskOp` does — parallel agents run
  schema-less and cache-cold.
- Agent task cost is rated against the *default* model even when an agent was
  created with a different one; thread the agent's actual model name into the
  dispatch-site charge.
- ~~`SummarizingCompressor` raw `(len / 4) + 4`~~ — ✅ routed through
  `TokenEstimate` (calibration sprint).

### 4. Estimate calibration from recorded fixtures — ✅ delivered 2026-08-06
`vaster_calibration`: the `TokenEstimator` seam (canonical heuristic
untouched), fitted profiles as data with provenance (`CalibrationCatalog`),
a tape fitter (median ratio, implausible samples excluded loudly,
estimated-source refused), the exact `LlamaTokenEstimator`, and
`vaster check --backend` composing profiles into cost bounds — the
prove-it loop closed within 1%. Error bounds asserted in tests; committed
constants re-derived from the fixture so they cannot rot. Tape v2
landed (full recorded requests): prompt-side fitting shipped and
proven on a recorded llama fixture. Remaining: grow the claude-cli
factor beyond n=1 (each future paid run is now a richer fixture
automatically).

### 5. TT-P4: resume from the debugger
The debugger can inspect and materialize any step; it cannot yet *resume live
execution* from one. `vaster debug --resume-at <step>` = seed a runtime from
the materialized state, swap the replay model for a live backend, continue.
This turns the debugger from a microscope into a surgery table (fix a bad
decision mid-run without re-paying the prefix).

### 6. Codify the sprint's rules
`rules.md` should absorb what this sprint established as law: the
`vaster_vm_api` boundary (runtime programs against the interface, never the
engine), the one-owner event-emission rule, the no-`late final`
constructor-graph rule, and the ABI-conventions homes
(`register_conventions.dart`, `AgentDescriptor.sessionIdFor`).

### 7. Backend robustness passes
- claude-cli cannot enforce `responseSchema` — JSON-steered ops (`DecideOp`,
  typed task returns) need self-defending prompt suffixes on CLI backends;
  today only some sites have them.
- gemini-cli hangs headless when auth-gated — needs a startup probe with a
  timeout and a typed "backend unavailable" error instead of a hang.
- `ExecutionStepFrame.modelOutput` is never populated (documented P7 gap);
  either populate it from the tape during recording or delete the field.

### 8. Rebuild `SharedMemoryRing` (vaster_mmap) — ✅ done 2026-08-05
The POSIX shared-memory ring was poorly structured and had correctness holes,
not just style debt:

- **No backpressure**: `writePacket` never checks free space against `tail` —
  the head can lap unread data and silently corrupt frames mid-read. The only
  guard is payload > total capacity.
- **No synchronization**: `head`/`tail`/`status` are plain struct fields with
  no atomics or memory barriers, so cross-process readers can observe torn
  updates; the `status` field (Idle/Ready/Busy) is written but never read —
  dead protocol surface.
- **"Zero-copy" is byte-at-a-time**: both copy loops go one byte per
  iteration through a modulo index instead of two-segment `setRange` copies.
- **Lifecycle bugs**: the constructor does FFI syscalls behind `late final`
  fields with a silent `catch (_)` around `shm_open`; failure paths leak the
  fd (never closed, even in `close()`); `close()` always `shm_unlink`s — even
  for the file fallback, and even when the peer process still uses the
  segment.
- **No owner/attach distinction**: every constructor `O_CREAT`s and
  re-initializes on magic mismatch, racing first-init between two processes.

Restructure into layers, each independently testable: `ShmSegment`
(open/attach/close with explicit owner-vs-attacher semantics, no `late`,
errors close what they opened), a pure `RingBuffer` (index arithmetic over a
`ByteData` — unit-testable with zero FFI), `FrameCodec` (length-prefix
framing), and a pluggable signal strategy (polling today, futex/pipe later).
Add free-space accounting with a typed `RingFull` result, and either real
atomics or a documented single-writer/single-reader discipline.

### 9. Observability export
The event bus already carries everything (`ModelUsageEvent` per call with full
usage JSON, tool timing, sandbox exits, compaction telemetry). A
`vaster_telemetry_otel` package mapping bus events onto OpenTelemetry
spans/metrics would make runs visible in any standard stack without touching
core packages — the same pattern as `vaster_pricing`: a leaf that only
consumes.

---

## Next big goals (strategic)

Larger arcs, each a multi-sprint program. Suggested order below, but 2 and 3
compound with everything and can start incrementally.

### A. Durable execution — ✅ delivered (thread 2; see above)
The natural endgame of what the replay/debugger work started. Machine state is
already serializable in pieces (registers, callstack snapshot, journal,
context regions, VBC program). The goal: **suspend any running pipeline to an
envelope, kill the process, resume days later** — including across HITL
pauses, which today hold the process hostage. `vaster_continuation` exists as
a stub of this idea; the debugger's materialized tier proved state
reconstruction works. Missing pieces: serializing live session history +
context heap as a first-class checkpoint, VFS snapshot/restore for
transactional mounts, and a `vaster resume <envelope>` CLI verb. This is the
feature that makes Vaster a *workflow runtime* rather than a script runner.

### B. Static verification — ✅ delivered (thread 3; see above), now calibrated
The program analyzer already does register liveness and session-reference
checks. Extend it toward real static guarantees:
- **Typed dataflow checking**: every `Binding` read has a dominating write
  (today only flat; make it control-flow-aware across jumps/branches).
- **Budget bounds**: worst-case token/cost estimate per program from the
  pricing catalog + loop bounds (`maxIterations` is already compiled in) —
  "this pipeline costs at most ~$X" *before* running it.
- **Policy verification**: prove no reachable instruction can violate the
  declared `ExecutionPolicy` (write outside allowed mounts, call unlisted
  tools) instead of trapping at runtime.
A `vaster check` CLI verb surfacing all three would be the differentiator no
prompt-orchestration framework has.

### C. Cache-aware context planning — substrate landed 2026-08-06
First steps shipped with the PV sprint: the ContextMmu is wired into
production (renderer-pluggable, MmuStats), KV reuse is token-exact
validated, and calibration prices tokens per backend. What remains IS
this goal: breakpoint placement against provider rules, and the
compactor's eviction-vs-cached-prefix cost function.
We measure cache hits (87.9% on the SDD run) but do not *plan* for them. The
context-class system knows what is stable (`cacheStable`, pinned regions,
band ordering); the cache-hint tracker knows what got pinned. Close the loop:
the linker should *place breakpoints optimally* given the provider's rules
(Anthropic 4-breakpoint budget, prefix invalidation), and the compactor should
weigh "eviction saves N tokens but invalidates a prefix worth M cached reads"
as a single cost function using real pricing. Measurable target: raise
cache-read share and cut $ / run on the recorded benchmarks.

### D. Reliability semantics (the runtime keeps promises)
Today a model error mid-pipeline traps (or an error handler catches it).
Production workflows need declared semantics: per-node **retry policies** with
backoff (✅ REL-P2: `Resilient` compiles to the canonical priced loop),
**model fallback chains** (✅ REL-P3: `SelectModel(fallbacks:)` — compiled
descriptor data, runtime-enforced fallthrough on model-kind failure, typed
`ModelFallbackEvent`s, serving-model metering attribution, audit lists the
chain, check rates its most expensive member), **idempotency keys** on tool
calls so retried turns do not double-execute side effects, and transactional
VFS as the default around every `Task` (REL-P4, pending). All of it belongs
in the AST surface and lowers to ISA the runtime enforces.

### E. Multi-run evaluation harness — ✅ delivered (vaster_eval; see above)
Replay gave us determinism for one run; the next level is *comparing* runs.
An eval package that executes a pipeline N times (or across backends/prompt
variants), scores outputs (model-graded or programmatic), and reports
cost/quality/latency per variant — reusing the envelope format as the storage
unit. This makes prompt and pipeline changes measurable instead of vibes, and
it is the internal customer for goals B (cost bounds) and C (cache savings).

### F. Distribution (later)
The RPC model backend and sandbox processes already cross process boundaries.
The far goal is crossing *machine* boundaries: remote sandbox pools, a
scheduler that dispatches quanta to workers, agents as actors with location
transparency (the messaging hub is already shaped for this). Deliberately
last: durable execution (A) is a prerequisite for any credible distributed
story, since work must survive worker loss.

---

## Suggested sequencing

| Horizon | Items |
|---|---|
| Now | 1 (v0.3.0 tag), 2 (CI), 3 (metering follow-ups) |
| Next sprint | 5 (TT-P4 resume), 8 (SharedMemoryRing rebuild), 6 (rules.md) |
| Soon after | 4 (estimate calibration), 7 (backend robustness), 9 (OTel) |
| This quarter | A (durable execution), B started (`vaster check` MVP) |
| Following | C (cache planning), D (reliability), E (eval harness) |
| Later | F (distribution) |


---

## The road to 1.0

**Definition: 1.0 means the promises are contracts.** Anything the README
claims is enforced by a test, bounded by `vaster check`, measured by
`vaster eval`, and stable across versions. Concretely, seven gates:

1. **Frozen formats with migration guarantees.** VBC, `MachineSnapshot`,
   `VasterContinuation`, `MachineCheckpoint`, and the replay envelope get a
   written spec and a compatibility promise: a checkpoint captured on 1.x
   resumes on any 1.y ≥ x (versioned migration, never silent rejection).
2. **The portability claim becomes testable.** An ISA reference document and
   a conformance suite a second-language runtime could pass — the suite
   exists at 1.0 even if the second runtime does not.
3. **Outside users exist.** Published to pub.dev, a docs site with the
   10-minute getting-started, ≥3 runnable examples, and at least one real
   workload owned by someone who is not us.
4. **Real-model reliability is engineered, not hoped.** Thread D shipped:
   declarative retry/fallback/idempotency (`Resilient` node, model chains),
   because the prove-it run showed real backends differ from fakes in kind.
   Gate: a benchmark set of workflows with PUBLISHED eval success rates and
   costs on ≥2 real backends, run in CI on recorded tapes and periodically
   live.
5. **The bold claim redeemed or cut.** ✅ REDEEMED (thread 4 + PV): real KV
   state moves engine → shared pages → engine as spec'd, validated images;
   warm resume measured live. Gate residue for 1.0: keep the transcripts
   reproducible and the format spec frozen.
6. **Hardened surface.** Fuzzed VBC decoder, an interpolation-injection
   suite beyond the single lock test, and a sandbox isolation audit.
7. **Operational completeness.** TT-P4 debugger resume, OTel export, and
   eval auto-respond for gated pipelines. (Per-backend calibrated
   estimates incl. the CLI-agentic overhead factor: ✅ shipped
   2026-08-06.)

Everything else — distribution, multi-node, cache planning beyond
measurement — is explicitly post-1.0.
