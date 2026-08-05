/// In-process llama.cpp inference over `dart:ffi`.
///
/// Three layers, each testable alone: [LlamaBindings] (hand-written symbol
/// surface, ABI pinned to the installed build), [LlamaEngine] (synchronous
/// deterministic engine — the state export/import kernel writes KV state
/// directly into caller-provided native memory), and [LlamaWorker] (the
/// engine hosted in a worker isolate, moving state to/from named
/// shared-memory frames without it ever crossing the message channel).
library;

export 'src/bindings/llama_bindings.dart'
    show LlamaBindings, LlamaModelParams, LlamaContextParams, LlamaBatch;
export 'src/llama_engine.dart'
    show LlamaEngine, LlamaStateIncompatibleException;
export 'src/llama_worker.dart' show LlamaWorker;
