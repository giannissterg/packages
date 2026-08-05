# Changelog

## Unreleased

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
