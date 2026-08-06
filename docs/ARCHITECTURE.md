# Vaster Architecture — the map

_The map, not the law: [rules.md](../rules.md) is binding; this document
shows where everything lives and why, so placement decisions are read,
not re-derived. If this file and rules.md disagree, rules.md wins._

## The layers

Dependencies point strictly downward. Nothing below the host line knows
the host exists; nothing right of a boundary imports leftward.

```text
┌──────────────────────────────────────────────────────────────────────┐
│ HOST — vaster_cli, vaster_playground                                 │
│ composition, backend resolution + lifecycle, park/prewarm policy     │
└───────────────┬──────────────────────────────────────────────────────┘
                │ may know everything; nothing knows it (Rule 10.6)
┌───────────────▼──────────────┐  ┌───────────────────────────────────┐
│ FRONTEND (Dart-coupled)      │  │ VERIFICATION & MEASUREMENT        │
│ vaster_ast · vaster_domain   │  │ vaster_check · vaster_eval        │
│ vaster_compiler              │  │ vaster_calibration · vaster_debug │
└───────────────┬──────────────┘  └───────────────────────────────────┘
                │ compiles to (never imported by anything below: Rule 1)
┌───────────────▼──────────────────────────────────────────────────────┐
│ ISA & FORMATS (language-agnostic, specified)                         │
│ vaster_instruction (ISA + VBC) · docs/specs/* · golden fixtures      │
└───────────────┬──────────────────────────────────────────────────────┘
                │ executed by
┌───────────────▼──────────────────────────────────────────────────────┐
│ MACHINE — vaster_runtime → vaster_vm_api ← vaster_vm                 │
│ vaster_machine_state (componentized state, snapshot/restore)         │
└───────────────┬──────────────────────────────────────────────────────┘
                │ composed of
┌───────────────▼──────────────────────────────────────────────────────┐
│ SUBSYSTEMS — sessions · context · agents · tools · sandboxes · fs ·  │
│ policy · budget · scheduler · events · metering · pricing · estimate │
└───────────────┬──────────────────────────────────────────────────────┘
                │ served by
┌───────────────▼───────────────────┐  ┌──────────────────────────────┐
│ MODEL BACKENDS (vaster_model_*,   │  │ DURABILITY BRIDGES           │
│ vaster_llama_ffi)                 │  │ vaster_continuation          │
│ engines own policy; workers       │  │ vaster_checkpoint            │
│ marshal (Rule 10.3)               │  │ vaster_replay                │
└───────────────┬───────────────────┘  └──────────────────────────────┘
                │ move bytes via
┌───────────────▼──────────────────────────────────────────────────────┐
│ TRANSPORTS & CONTAINERS — vaster_mmap (segments/rings/frames,        │
│ envelopes, ring host) · vaster_model_rpc(+_server) (UDS)             │
│ bytes only: no domain validation, no fabricated success (Rules 9,10) │
└──────────────────────────────────────────────────────────────────────┘
```

## The KV/context vertical — a worked example of the placement law

The virtual-memory metaphor, one package per concept, each knowing the
minimum:

| concept | package | knows | must not know |
|---|---|---|---|
| virtual pages (`ContextRegion`, classes, budgets) | `vaster_context` | itself | physical anything |
| the allocator/linker (`compileContext`) | `vaster_context_manager` | regions | KV, transports |
| **the page table** (`ContextMmu`) | `vaster_context_mmu` | **both sides** — the only one (Rule 6.15) | transports, engines |
| physical contracts + format (`KvCacheController`, `KvStateImage`) | `vaster_kv` (leaf, guard-tested) | token estimation only | context, transports, engines |
| physical backends (state-addressed) | `vaster_llama_ffi`, `vaster_kv_mmap` | contracts + transport | context layer |
| physical backends (content-addressed) | `vaster_model_claude_api`, … | cache hints | frames, images |
| container + wire (`SharedMemoryFrame`, `kvFrameName`, envelopes) | `vaster_mmap` | bytes | what the bytes mean |
| prewarm/park orchestration | `vaster_cli` | everything | — (host) |

Two backend classes, one safety property: state-addressed backends
validate reuse themselves (token-exact, engineTag — spec'd in
[KV_STATE_IMAGE.md](specs/KV_STATE_IMAGE.md), executed engine-side);
content-addressed backends inherit it from the server's exact-prefix
cache semantics. A mismatch is never wrong output — cold decode or cache
miss, respectively.

## Where a new piece of logic goes (Rule 10, applied)

- A new **interface or binary format** → a leaf package beside its
  contract, with a spec in `docs/specs/` and a golden fixture.
- A new **transport** (file store, socket flavor, future fabric) → its
  own package; it carries formats, never owns or validates them.
- A new **inference engine** → `vaster_<engine>_ffi`-style backend
  package: engine class owns policy and validation, worker/host layers
  marshal; it depends on contracts (`vaster_kv`, `vaster_model`) and a
  transport — never on the context layer (the leaf guard will catch you).
- Logic that must know **two layers** → a dedicated bridge package, and
  that knowledge exists nowhere else.
- **Composition, lifecycle, operational policy** → the host (CLI).

## Enforcement — the rules that run

| invariant | enforced by |
|---|---|
| frontend never reaches runtime (Rule 1) | package graph; runtime tests build raw ISA |
| runtime ↛ engine (`vaster_vm_api`) | package graph |
| `vaster_kv` leaf-ness (Rule 6.15) | `leaf_guard_test` (direct deps + closure walk) |
| machine state completeness (Rule 8) | checkpoint-anywhere gauntlet |
| SPSC/publication order (Rule 9) | cross-isolate parallel stress tests |
| format byte-compatibility | golden fixtures (`kv_state_image_test`) |
| calibration constants match the data | refit-from-fixture + error-bound tests (`calibration_test`) |
| compiler+runtime+metering vs reality | committed replay fixture (zero-cost) |
| README quickstart honesty | `readme_quickstart_check` mirror |

## Specs index

- [KV_STATE_IMAGE.md](specs/KV_STATE_IMAGE.md) — physical KV state +
  reuse provenance (v1). Further frozen formats (VBC, snapshots,
  checkpoints, envelopes) land here on the road to 1.0 (gate 1).
