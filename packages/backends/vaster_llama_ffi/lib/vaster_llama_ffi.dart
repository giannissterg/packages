/// In-process llama.cpp inference over `dart:ffi`.
///
/// Three layers, each testable alone: [LlamaBindings] (hand-written symbol
/// surface, ABI pinned to the installed build), [LlamaEngine] (synchronous
/// deterministic engine — the state export/import kernel writes KV state
/// directly into caller-provided native memory), and [LlamaWorker] (the
/// engine hosted in a worker isolate, moving state to/from named
/// shared-memory frames without it ever crossing the message channel).
///
/// To serve this backend over shared-memory rings, pair the model with
/// `RingSidecarHost` from `vaster_mmap` — the host is transport code and
/// backend-agnostic, so it does not live here.
library;

export 'src/bindings/llama_bindings.dart'
    show LlamaBindings, LlamaModelParams, LlamaContextParams, LlamaBatch;
export 'src/llama_engine.dart'
    show
        LlamaEngine,
        LlamaStateIncompatibleException,
        KvReuse,
        KvReuseNone,
        KvReuseValidated,
        KvReuseRejected;
export 'src/llama_ffi_kv_cache_controller.dart' show LlamaFfiKvCacheController;
export 'src/llama_ffi_vaster_model.dart' show LlamaFfiVasterModel;
export 'src/llama_prompt_composer.dart' show LlamaPromptComposer;
export 'src/llama_token_estimator.dart' show LlamaTokenEstimator;
export 'src/llama_worker.dart' show LlamaWorker;
