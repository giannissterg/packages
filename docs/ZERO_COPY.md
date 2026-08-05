# Zero-Copy KV State — the claim, redeemed

_2026-08-06. Thread 4 of the roadmap: real llama.cpp inference over
`dart:ffi`, with KV-cache state crossing process boundaries through
shared-memory pages. Every transcript below is a real run against the
tree it's committed to._

## The claim, stated precisely

**Bulk context and KV-cache state cross process boundaries via shared
memory pages; the ring transport carries only small JSON envelopes.**
The one unavoidable copy is engine↔buffer: `llama_state_seq_get_data` /
`set_data` flatten ggml tensor state into a caller-provided buffer — and
our buffer *is* the mapped frame (`SharedMemoryFrame.payloadPointer`), so
state moves engine → shared pages → engine with no files, no sockets, no
Dart-heap staging, and no serialization layer. What this is **not**: the
GPU/compute path does not read shm directly, and frames are portable only
across the same llama.cpp build (its state format is the authority —
`set_data` rejecting a blob is surfaced as a typed
`LlamaStateIncompatibleException`, never a silent cold start).

## Setup

```bash
brew install llama.cpp        # ships libllama.dylib + headers (build 10280 verified)
mkdir -p ~/models
curl -L -o ~/models/stories15M-q4_0.gguf \
  "https://huggingface.co/ggml-org/models/resolve/main/tinyllamas/stories15M-q4_0.gguf"          # 18MB, CI tier
curl -L -o ~/models/SmolLM2-135M-Instruct-Q4_K_M.gguf \
  "https://huggingface.co/bartowski/SmolLM2-135M-Instruct-GGUF/resolve/main/SmolLM2-135M-Instruct-Q4_K_M.gguf"  # 101MB, demo tier
vaster doctor                 # ✓ libllama (all symbols resolve), ✓ llama model
```

`vaster_llama_ffi` binds libllama by hand (no generator), hosts the
engine in a worker isolate (blocking `llama_decode` never stalls the VM
event loop), and runs CPU-only, single-threaded, greedy by default — the
determinism recipe every equivalence proof below relies on.

## Proof 1 — the kernel (engine level)

State exported from one context, restored into a **fresh** context,
continues token-identically. From the test suite
(`llama_engine_test.dart`, runs on every `dart test`):

- export writes **directly into shared frame pages**
  (`exportStateInto(frame.payloadPointer, size)` — exact-size frame,
  fully written), restore reads from an attachment's pages;
- the restored engine's next greedy token equals the original's;
- sampling before any decode in a restored context is a typed error —
  logits do not travel with KV state (natively it's a process-killing
  `GGML_ASSERT`);
- a garbage blob raises `LlamaStateIncompatibleException`.

Measured state sizes at this scale: stories15M ≈ 7KB/token, SmolLM2-135M
≈ 23KB/token — a 105-token pinned prefix is a ~2.4MB frame.

## Proof 2 — the resume that doesn't re-pay its prefix (process level)

The durability payoff, tying thread 4 to thread 2. `story_scribe`
(12 instructions): pinned knowledge → model turn → **human gate** →
post-approval model turn.

```
$ dart run vaster_playground:compile_zero_copy
compiled 12 instructions → artifacts/zero_copy/story_scribe.vbc

$ vaster run artifacts/zero_copy/story_scribe.vbc --backend llama \
    --model ~/models/stories15M-q4_0.gguf --checkpoint-dir artifacts/zero_copy/ckpts
── PARKED (durable) ────────────────────────────────────
  awaiting: Continue this story?
  checkpoint: artifacts/zero_copy/ckpts/story_scribe_continue_gate.ckpt.json
  kv-prewarm: 1 pinned region(s) → shared frames (105 tokens)   (exit 3)

# …the process is gone. A fresh process:

$ vaster resume artifacts/zero_copy/ckpts/story_scribe_continue_gate.ckpt.json \
    --backend llama --model ~/models/stories15M-q4_0.gguf --respond approve
── RESUME COMPLETE ────────────────────────────────────
  status : halted
  cache  : 105 of 276 prompt tokens restored from KV state — never re-decoded
```

At park, every pinned region's model-rendered form is materialized into
a content-addressed frame (`kv-prewarm`). The resuming process's model
call carries the region's fingerprint as a cache hint, discovers the
frame the dead process left behind by named-segment attach, hands its
pages to `set_data`, and decodes only the remainder. The `cache` line is
engine-measured: those 105 tokens were physically never decoded again.

## Proof 3 — the sidecar topology (ring level)

`vaster serve --backend llama` hosts the engine; clients are
`MmapVasterModel` on the same ring pair. The E2E test
(`llama_sidecar_host_test.dart`) proves the full wire path: a cold call
round-trips the rings; the warm call's envelope carries only a frame
*reference* (`kvFrames: [{frameName, contentFingerprint, tokenCount}]`),
the sidecar restores from the named pages, and the completion is
**identical to the cold one** with `cacheReadTokenCount` equal to the
materialized prefix. The transport is honest end to end: no sidecar →
typed `SidecarUnavailableException`; sidecar failure → typed
`SidecarRemoteException`. The pre-0.5 stub that fabricated success on
timeout is gone — and deleting it immediately exposed two real bugs it
had been hiding (a half-duplex self-consumption race, and a SIGSEGV when
a poll loop outlives its ring), both now fixed and locked by tests.

## Trust boundary (stated, not hidden)

KV state is positional. Reuse assumes the composed prompt's leading
tokens equal the materialized content's tokens; the alignment contract
is `LlamaFfiVasterModel.renderMessages` — prewarm materializes exactly
what the prompt composer will render, and stable content renders first.
The equivalence tests (warm == cold) validate the contract empirically
on every run. Token-exact prefix validation via the `ContextMmu` page
table is the planned hardening; a mismatched (colliding) fingerprint
today would produce a wrong-context completion, not a crash.

## What isolates can't prove, transcripts do

Automated tests prove the mechanics in-process (fresh engines, fresh
controllers, attach-by-name, parallel-isolate SPSC). The one property
they cannot reach — **state surviving process death** — is proven by the
Proof 2 transcript above, re-runnable by hand, the same standing
PROVE_IT.md has for durable execution.
