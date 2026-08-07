# Reliability — measured, not hoped

_Gate 4's evidence (ROADMAP §1.0). Reliability semantics are declared in
the AST, compiled to ISA, enforced by the runtime — and this document is
where they stop being a claim: a benchmark set that runs at zero token
cost on every push, plus a documented protocol for periodic live runs on
real backends._

The set lives in `packages/host/vaster_benchmarks`
(`ReliabilityBenchmarks.builtin`); the CI test
(`reliability_benchmarks_test.dart`) runs it in the sweep and prints this
table. Two families:

- **Tape benchmarks** replay REAL recorded backend traffic through the
  current toolchain — compiler, runtime, metering — and lock the exact
  recorded totals, token for token, cent for cent. Two real backends are
  on tape: **claude-cli** (the 2026-08-05 SDD run: 4 calls, 87.9% cache
  reads, wire-reported cost) and **llama-ffi** (stories15M, real local
  inference).
- **Fault benchmarks** compile from the AST and inject the failures a
  live backend cannot produce on demand — a transient outage, a dead
  primary, a model dying mid-turn after its tool ran. They prove the
  REL-P2/P3/P4 semantics hold, every push.

## Published CI numbers (2026-08-07, commits through GAP-3)

| benchmark | exercises | backend | trials | success | tokens | cost |
|---|---|---|---|---|---|---|
| sdd_multi_agent | multi-agent Tasks (transactional by default), sessions, artifact writes, usage fidelity | tape:claude-cli | 1 | 1/1 | 450302 | $0.825917 |
| story_lines_llama | prompt chaining, local-inference fidelity (second real backend) | tape:llama-ffi | 1 | 1/1 | 2028 | — |
| retry_heals | Resilient retry loop (REL-P2): transient failures heal within the declared ceiling | fault:500-500-ok | 3 | 3/3 | 30 | — |
| fallback_serves | SelectModel fallback chain (REL-P3): model-kind failure falls through, fallback serves | fault:dead-primary | 3 | 3/3 | 51 | — |
| effects_once | effect ledger (REL-P4): a retried turn replays tool results instead of re-executing side effects | fault:die-after-tool | 3 | 3/3 | 96 | — |
| agent_effects_once | agent-internal effect replay (GAP-3a): a re-dispatched task never re-executes its predecessor's tool effects | fault:die-mid-task | 3 | 3/3 | 129 | — |

Tape rows are **fidelity locks**: the CI test asserts the replayed totals
equal the recorded run's exactly — a drifted number fails the build.
Fault rows measure with fakes, so tokens are labeled estimates and cost is
honestly absent (`vaster_token_estimate` discipline: estimates are
labeled, never passed off as measurement).

## What each fault benchmark asserts

- **retry_heals** — the model 500s twice; the third attempt serves. The
  compiled retry loop (constant size, priced by `vaster check` at the
  declared ceiling) converts a transient outage into a success.
- **fallback_serves** — the primary is dead; the declared
  `SelectModel(fallbacks:)` chain serves the call from the fallback
  member. The chain is compiled descriptor data — `vaster audit` lists
  it, `vaster dis` renders it, `check` prices its most expensive member.
- **effects_once** — the model calls a side-effecting tool, dies
  mid-turn, and the retried attempt REPLAYS the recorded tool result.
  The tool reports its own execution count; the final answer must carry
  `executions=1`. This is REL-P4's exactly-once claim, scored.
- **agent_effects_once** — the same claim one layer down (GAP-3a): the
  tool call happens INSIDE an agent task, the task dies after the tool
  ran, and the retried dispatch re-runs the agent — whose tool call
  replays through the dispatch's effect region. Same `executions=1`
  scoring; this row is the measurable definition of agent parity.

## The live-run protocol

Live runs measure what tapes cannot: current backend behavior. They cost
real money, so they are periodic and deliberate, not per-push.

**Cadence**: before each tagged release, and after any backend/prompt
change that the tape benchmarks cannot cover (new provider, new model
family). Record every run's envelope — a live run is also a new tape.

```bash
# 1. Export the live-runnable benchmarks as compiled artifacts.
dart run vaster_benchmarks:export        # → artifacts/benchmarks/*.vbc

# 2. Prove the cost bound BEFORE spending (per backend/model).
vaster check artifacts/benchmarks/sdd_multi_agent.vbc --model claude-opus-5

# 3. Run N trials per backend.
vaster eval artifacts/benchmarks/sdd_multi_agent.vbc \
    --backend claude-cli -n 3 --contains APPROVE --json \
    > artifacts/benchmarks/live_sdd_claude_$(date +%Y%m%d).json
vaster eval artifacts/benchmarks/story_lines_llama.vbc \
    --backend rpc -n 3 --json \
    > artifacts/benchmarks/live_story_llama_$(date +%Y%m%d).json
vaster eval artifacts/benchmarks/retry_heals.vbc \
    --backend claude-cli -n 3 --contains recovered --json \
    > artifacts/benchmarks/live_retry_claude_$(date +%Y%m%d).json

# 4. Record ONE run per backend as a fresh tape (a live run is also a
#    future zero-cost regression fixture):
vaster run artifacts/benchmarks/sdd_multi_agent.vbc \
    --backend claude-cli --record artifacts/benchmarks/sdd_$(date +%Y%m%d).replay.json

# 5. Publish: append a dated row block below with the reported
#    success/tokens/cost, and commit the JSON artifacts.
```

`retry_heals` on a live backend usually succeeds on attempt 1 — that is
the point: it measures the real transient-failure rate of the backend and
proves the declared ceiling absorbs it when it fires. The two
fault-injection benchmarks that need injected models (`fallback_serves`,
`effects_once`) are CI-only, by design.

## Live-run history

| date | backend | benchmark | trials | success | tokens | cost |
|---|---|---|---|---|---|---|
| 2026-08-05 | claude-cli (real) | sdd_multi_agent (recorded → tape) | 1 | 1/1 | 450302 | $0.825917 |
| 2026-08-05 | llama-ffi stories15M (real, local) | story_lines_llama (recorded → tape) | 1 | 1/1 | 2028 | $0 (local) |

_Every future live run appends here, dated, with its JSON artifact
committed alongside._
