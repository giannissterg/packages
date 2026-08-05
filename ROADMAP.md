# Vaster Roadmap

_Last updated: 2026-08-05, after the architectural-review sprint (AR-1..AR-5)._

## Where we are

The kernel is in place and honest:

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
- **514 → 520 tests green**, analyzer clean, 56 workspace packages.

---

## Next improvements (near-term, concrete)

Ordered roughly by value-for-effort. Each is a self-contained sprint or less.

### 1. Release v0.3.0
Four of the five AR phases are breaking (`vaster_vm_api` extraction, required
ownership params, interface promotion, package moves). Roll the `Unreleased`
CHANGELOG sections into 0.3.0, bump pubspecs, tag. Cheap, and it puts a stake
in the ground before the next breaking wave.

### 2. CI pipeline
There is no CI. A GitHub Actions workflow that runs `dart analyze packages`,
the full test sweep, and a replay of `sdd_fidelity.replay.json` (zero-cost,
asserts byte-exact usage totals) would catch regressions the moment they land.
The fixture replay is the crown jewel here — it is a free end-to-end test of
compiler + runtime + metering against real recorded model traffic.

### 3. Metering follow-ups
- `DispatchParallelTasksOp` does not forward `responseSchema`/`cacheHints`
  per dispatch the way `DispatchAgentTaskOp` does — parallel agents run
  schema-less and cache-cold.
- Agent task cost is rated against the *default* model even when an agent was
  created with a different one; thread the agent's actual model name into the
  dispatch-site charge.
- `SummarizingCompressor` still sizes its output region with a raw
  `(len / 4) + 4` at one spot — route it through `TokenEstimate` for
  consistency.

### 4. Estimate calibration from recorded fixtures
`TokenEstimate` is a flat `len / 4`. We now own real recordings with measured
usage per prompt — enough to fit per-backend chars-per-token ratios (system
text vs code vs JSON differ materially) and assert estimate error bounds in
tests. Keeps the honest-fallback path honest.

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

### A. Durable execution (continuations that survive the process)
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

### B. Static verification (the compiler earns its name)
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

### C. Cache-aware context planning
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
backoff, **model fallback chains** (`SelectModel` accepting an ordered list),
**idempotency keys** on tool calls so retried turns do not double-execute side
effects, and transactional VFS as the default around every `Task`. All of it
belongs in the AST surface (`Resilient(child:, retries:, fallback:)` is
already sketched in the NEST-vs-SEQUENCE doc) and lowers to ISA the runtime
enforces.

### E. Multi-run evaluation harness
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
