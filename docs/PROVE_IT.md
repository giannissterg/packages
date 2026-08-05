# The Prove-It Run — v0.4.0 on a real backend

_2026-08-06. One genuinely useful workflow, end to end, on claude-cli, with
every part of the promise engaged. Artifacts in `artifacts/prove_it/`._

## The workflow

`release_scribe` (17 instructions): pinned release-facts knowledge → draft
the v0.4.0 announcement → self-tighten in the same session → **human
approval gate** → write `RELEASE_NOTES.md` to a **disk mount** → declared
result `outcome`. Program-declared budget: 60k tokens / $2.

## The transcript

```
$ dart run vaster_playground:compile_prove_it
compiled 17 instructions → artifacts/prove_it/release_scribe.vbc

$ vaster check release_scribe.vbc --model claude-opus-5 --max-cost 2 \
    --policy artifacts/prove_it/workspace_policy.json
  bound   : ≤2 model calls, ≤2163 tokens, ≤$0.0518
  policy  : workspace_writer — no proven violations, fully proven
  findings: none — clean

$ vaster check release_scribe.vbc --policy read-only        # negative proof
  [error] policy_violation_proven: pc 12 file:write on
  "/workspace/RELEASE_NOTES.md" — this WILL trap at runtime.  (exit 1)

$ vaster run release_scribe.vbc --backend claude-cli \
    --checkpoint-dir artifacts/prove_it/ckpts
── PARKED (durable) ── awaiting: Publish this announcement…?  (exit 3)

# …the process is gone. Later, a different process:

$ vaster resume ckpts/release_scribe_publish_gate.ckpt.json \
    --backend claude-cli --respond approve
  Meters  : 46716 tokens / $0.115653 already spent
── RESUME COMPLETE ── status: halted
  tokens : 46716 total (0 this resume)
  output : published
```

`artifacts/prove_it/workspace/RELEASE_NOTES.md` exists on real disk, written
by the approve branch after the process boundary.

## What worked

- **Static proofs held**: the shipping policy proved clean; `read-only`
  caught the write at the exact pc with exit 1 — before any spend.
- **Durable parking held**: park (exit 3) → fresh VM from JSON alone →
  approval → completion; the host budget continued from $0.115653 with the
  approve branch honestly costing 0 new tokens.
- **Real metering held**: wire-reported claude-cli cost (`total_cost_usd`)
  charged, not estimated; the program's $2 `BudgetScope` was enforced
  machinery, not decoration.

## What the real backend taught us (why this run existed)

1. **Bug found and fixed: the mount table is machine state.** The first
   resume trapped resolving `/workspace` — the checkpoint carried memory
   -mount *files* but not the mount *table*, so a pre-gate `MountFsOp`'s
   disk mount was never re-established in the fresh VM. Fake-model suites
   never caught it because they used the default memory root. Fixed
   (checkpoint `diskMounts`), locked by the DISK MOUNT SURVIVAL test.
2. **Static cost bounds assume API-shaped calls.** The bound said ≤$0.0518
   (2 prompt→completion calls); reality was $0.1157 — claude-cli is an
   *agentic* backend that explores the repo inside its own harness, so
   per-call token usage dwarfs the prompt estimate. The bound is sound for
   API backends; for CLI-agentic ones it needs a per-backend call-overhead
   factor (feeds the estimate-calibration thread). The *runtime* budget was
   the working defense, exactly as designed.
3. **Agentic backends read the world, not just the context.** The draft
   cited real git history (sprint codenames, dates) beyond the pinned
   knowledge — "use ONLY the facts in your context" is not enforceable on a
   backend with repo access. Context discipline differs per backend class;
   worth a capability flag and documentation.

## Verdict

The machine's promise — check → run → die → resume → artifact — is now
demonstrated on a real model, with real money metered, and the run
generated two findings no amount of fake-model testing had produced. This
is what the outward pivot is for.
