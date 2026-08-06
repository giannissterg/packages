# Changelog

## Unreleased

- **PV-P2: reuse is validated, never trusted.** Materialized frames now
  carry `KvStateImage` payloads (spec v1): header, fingerprint, the
  decoded token ids, and engine state exported in place at the image's
  state offset. Every reuse attempt runs the spec's consuming steps
  engine-side in `LlamaEngine.continueFromImage` — producer identity
  (`engineTag`, derived from libllama + model file) and token-exact
  prefix validation happen BEFORE any restore; every rejection
  cold-decodes, and the sealed `KvReuse` outcome (validated /
  rejected(reason, divergenceIndex) / none) is surfaced in
  `ModelResponse.rawResponse.kvReuse`. `tokenize` returns `Int32List`;
  prefill copies through typed views.
- Frames are namespaced **per producer** (the engine tag joins the name
  prefix): two models cannot collide on a content-addressed name, and a
  format migration cannot leave a stale frame squatting on a name this
  producer will look up. `lookup` validates the image and unlinks
  unparseable squatters, so discovery never reports a frame every
  consumer would reject.
- The first live catch: validation rejected (`prefix-mismatch` at token
  3) a reuse the old trusting path had been happily performing in the
  CLI transcript — sessionless `PromptOp`s never receive pinned context
  in their composed prompt, so the old "105 of 276 restored" was a
  wrong-context generation masked by small-model output. The VM-side
  gap is tracked for the next fix; the docs' transcript is invalid until
  then.

- Generation policy consolidated into `LlamaEngine`:
  `prefillContinuation` (prefix reuse incl. impossible-reuse and
  exact-cover tail re-decode) and `generateSteps` (THE greedy loop —
  `generateText` and every worker op delegate to it) are engine methods
  now; the worker's dispatch table is pure marshalling. One owner per
  algorithm, covered by direct engine tests.
- `LlamaFfiVasterModel.kvController` → `frameResolver`, narrowed to the
  `KvFrameResolver` interface — the model only ever resolves fingerprints
  to frame names (mirroring `MmapVasterModel.frameResolver`); the
  concrete controller pairing is the host/resolver's business.

- `LlamaSidecarHost` moved to `vaster_mmap` as the backend-agnostic
  `RingSidecarHost` — serving over rings is transport, not a llama
  concern. Pair it with `LlamaFfiVasterModel` for the zero-copy topology.

- ZC-P5: the sidecar over the rings. `LlamaSidecarHost` serves `generate`
  envelopes from a request ring (errors typed on the wire);
  `LlamaFfiKvCacheController` now also implements `KvFrameResolver`, so
  `MmapVasterModel` clients lower hints to frame refs — only names cross
  the ring. Proven: client↔sidecar warm call restores KV from frames and
  matches the cold completion exactly.

- ZC-P3: the zero-copy model layer.
  - `LlamaFfiKvCacheController` — `KvCacheController` whose frames hold
    real KV tensor state: materialize prefills and exports directly into a
    content-addressed frame's pages; restore hands attached pages back to
    the engine; lookup falls back to named-segment attach (cross-process
    discovery); evict unlinks. Idempotent per fingerprint.
  - `LlamaFfiVasterModel` — `VasterModel` honoring cache hints
    *physically*: a resolving hint restores KV state from shared pages and
    only the prompt remainder is decoded. Engine-measured usage
    (`cacheReadTokenCount` = skipped prefix tokens); prompt composition
    keeps stable content first (prefix trust boundary documented, MMU
    token-exact validation lands in ZC-P5). Proven by test: warm output
    is token-identical to cold on stories15M.
  - Worker gains `decodeText`, `prefillContinuation` (restored-prefix
    reuse incl. the exact-cover tail-re-decode case), `generateSteps`;
    engine gains `dropTail`.

- Initial package (ZC-P2): in-process llama.cpp inference over `dart:ffi`.
  - `LlamaBindings` — hand-written symbol surface transcribed from the
    installed `llama.h` (brew build 10280, validated by the ZC-P0 probe);
    every lookup eager, missing symbols fail at open. Process-global log
    silencing via a native no-op inside libllama itself — never a Dart
    trampoline (the callback outlives isolates and fires from any thread).
  - `LlamaEngine` — synchronous deterministic engine (CPU, 1 thread,
    greedy): tokenize, chunked prefill, sampling, and the zero-copy state
    kernel — `exportStateInto`/`importStateFrom` move sequence KV state
    directly between the engine and caller-provided native memory (e.g. a
    `SharedMemoryFrame.payloadPointer`). Typed
    `LlamaStateIncompatibleException` on rejected blobs; sampling before
    any decode is a typed error, not the native abort it would otherwise
    be (logits do not travel with KV state).
  - `LlamaWorker` — the engine hosted in a worker isolate so blocking
    `llama_decode` never stalls the VM event loop; KV state moves via
    named shared-memory frames on the worker side, never through the
    message channel. A fresh worker resumes generation from a frame alone
    (proven by test on stories15M).
