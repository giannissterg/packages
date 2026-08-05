/// Hand-written `dart:ffi` bindings for libllama, following the package's
/// `PosixShmBindings` house style: no generator, only the surface the
/// engine needs, every signature transcribed from the installed header.
///
/// ### ABI provenance
/// Struct layouts are transcribed from `llama.h` of **brew build 10280**
/// (validated end-to-end by the ZC-P0 probe: struct-by-value default
/// params round-trip, model load, decode, and a token-identical
/// state-restore continuation). The layouts are build-specific — a
/// different llama.cpp may reorder or add fields. [LlamaBindings.open]
/// therefore verifies the presence of every symbol it needs up front, and
/// the engine treats `llama_state_seq_set_data` returning 0 as the typed
/// incompatible-state signal rather than trusting version numbers.
library;

import 'dart:ffi';

/// `struct llama_model_params` (llama.h build 10280).
final class LlamaModelParams extends Struct {
  external Pointer<Void> devices;
  external Pointer<Void> tensorBuftOverrides;
  @Int32()
  external int nGpuLayers;
  @Int32()
  external int splitMode;
  @Int32()
  external int loadMode;
  @Int32()
  external int mainGpu;
  external Pointer<Void> tensorSplit;
  external Pointer<Void> progressCallback;
  external Pointer<Void> progressCallbackUserData;
  external Pointer<Void> kvOverrides;
  @Bool()
  external bool vocabOnly;
  @Bool()
  external bool checkTensors;
  @Bool()
  external bool useExtraBufts;
  @Bool()
  external bool noHost;
  @Bool()
  external bool noAlloc;
  @Bool()
  external bool loadMtp;
}

/// `struct llama_context_params` (llama.h build 10280).
final class LlamaContextParams extends Struct {
  @Uint32()
  external int nCtx;
  @Uint32()
  external int nBatch;
  @Uint32()
  external int nUbatch;
  @Uint32()
  external int nSeqMax;
  @Uint32()
  external int nRsSeq;
  @Uint32()
  external int nOutputsMax;
  @Int32()
  external int nThreads;
  @Int32()
  external int nThreadsBatch;
  @Int32()
  external int ctxType;
  @Int32()
  external int ropeScalingType;
  @Int32()
  external int poolingType;
  @Int32()
  external int attentionType;
  @Int32()
  external int flashAttnType;
  @Float()
  external double ropeFreqBase;
  @Float()
  external double ropeFreqScale;
  @Float()
  external double yarnExtFactor;
  @Float()
  external double yarnAttnFactor;
  @Float()
  external double yarnBetaFast;
  @Float()
  external double yarnBetaSlow;
  @Uint32()
  external int yarnOrigCtx;
  @Float()
  external double defragThold;
  external Pointer<Void> cbEval;
  external Pointer<Void> cbEvalUserData;
  @Int32()
  external int typeK;
  @Int32()
  external int typeV;
  external Pointer<Void> abortCallback;
  external Pointer<Void> abortCallbackData;
  @Bool()
  external bool embeddings;
  @Bool()
  external bool offloadKqv;
  @Bool()
  external bool noPerf;
  @Bool()
  external bool opOffload;
  @Bool()
  external bool swaFull;
  @Bool()
  external bool kvUnified;
  external Pointer<Void> samplers;
  @Size()
  external int nSamplers;
  external Pointer<Void> ctxOther;
}

/// `struct llama_batch` (llama.h build 10280). `pos`/`seq_id` may be null —
/// positions are then tracked by the context (llama.h:246).
final class LlamaBatch extends Struct {
  @Int32()
  external int nTokens;
  external Pointer<Int32> token;
  external Pointer<Float> embd;
  external Pointer<Int32> pos;
  external Pointer<Int32> nSeqId;
  external Pointer<Pointer<Int32>> seqId;
  external Pointer<Int8> logits;
}

/// `ggml_log_callback` — `void (*)(int level, const char* text, void* ud)`.
typedef GgmlLogCallbackNative = Void Function(
    Int32, Pointer<Uint8>, Pointer<Void>);

/// The libllama function surface the engine uses. All lookups happen
/// eagerly in [open] — a missing symbol fails loudly at construction, not
/// mid-inference.
final class LlamaBindings {
  final DynamicLibrary library;

  final void Function() backendInit;
  final void Function(Pointer<NativeFunction<GgmlLogCallbackNative>>,
      Pointer<Void>) logSet;
  final LlamaModelParams Function() modelDefaultParams;
  final LlamaContextParams Function() contextDefaultParams;
  final Pointer<Void> Function(Pointer<Uint8>, LlamaModelParams)
      modelLoadFromFile;
  final void Function(Pointer<Void>) modelFree;
  final Pointer<Void> Function(Pointer<Void>, LlamaContextParams)
      initFromModel;
  final void Function(Pointer<Void>) contextFree;
  final int Function(Pointer<Void>) nCtx;
  final Pointer<Void> Function(Pointer<Void>) modelGetVocab;
  final int Function(
          Pointer<Void>, Pointer<Uint8>, int, Pointer<Int32>, int, bool, bool)
      tokenize;
  final int Function(Pointer<Void>, int, Pointer<Uint8>, int, int, bool)
      tokenToPiece;
  final bool Function(Pointer<Void>, int) vocabIsEog;
  final LlamaBatch Function(Pointer<Int32>, int) batchGetOne;
  final int Function(Pointer<Void>, LlamaBatch) decode;
  final Pointer<Void> Function() samplerInitGreedy;
  final void Function(Pointer<Void>) samplerFree;
  final int Function(Pointer<Void>, Pointer<Void>, int) samplerSample;
  final int Function(Pointer<Void>, int) stateSeqGetSize;
  final int Function(Pointer<Void>, Pointer<Uint8>, int, int) stateSeqGetData;
  final int Function(Pointer<Void>, Pointer<Uint8>, int, int) stateSeqSetData;
  final Pointer<Void> Function(Pointer<Void>) getMemory;
  final bool Function(Pointer<Void>, int, int, int) memorySeqRm;
  final int Function(Pointer<Void>, int) memorySeqPosMax;

  LlamaBindings._({
    required this.library,
    required this.backendInit,
    required this.logSet,
    required this.modelDefaultParams,
    required this.contextDefaultParams,
    required this.modelLoadFromFile,
    required this.modelFree,
    required this.initFromModel,
    required this.contextFree,
    required this.nCtx,
    required this.modelGetVocab,
    required this.tokenize,
    required this.tokenToPiece,
    required this.vocabIsEog,
    required this.batchGetOne,
    required this.decode,
    required this.samplerInitGreedy,
    required this.samplerFree,
    required this.samplerSample,
    required this.stateSeqGetSize,
    required this.stateSeqGetData,
    required this.stateSeqSetData,
    required this.getMemory,
    required this.memorySeqRm,
    required this.memorySeqPosMax,
  });

  /// Default install location of the Homebrew bottle on macOS.
  static const String defaultLibraryPath = '/opt/homebrew/lib/libllama.dylib';

  /// Silences ggml/llama logging for the whole process.
  ///
  /// The log callback is **process-global** (last `llama_log_set` wins) and
  /// may be invoked from any native thread at any time — including after a
  /// Dart isolate that installed a `NativeCallable` has died, which makes
  /// Dart-side callbacks a use-after-free trap. So no Dart trampoline:
  /// the callback is pointed at `llama_supports_mmap`, a no-arg,
  /// side-effect-free function inside libllama itself. On the supported
  /// ABIs (AAPCS64, SysV x86-64) the caller's three arguments land in
  /// registers the callee never reads, and the unread bool return is
  /// harmless — a permanently-valid native no-op.
  void silenceLogs() {
    final noop = library
        .lookup<NativeFunction<GgmlLogCallbackNative>>('llama_supports_mmap');
    logSet(noop, nullptr);
  }

  /// Opens [libraryPath] and resolves every symbol eagerly. Throws
  /// [ArgumentError] when the library or any symbol is missing — the error
  /// names what is absent so an incompatible llama.cpp build is diagnosed
  /// at load time.
  factory LlamaBindings.open({String libraryPath = defaultLibraryPath}) {
    final lib = DynamicLibrary.open(libraryPath);
    return LlamaBindings._(
      library: lib,
      backendInit: lib
          .lookupFunction<Void Function(), void Function()>(
              'llama_backend_init'),
      logSet: lib.lookupFunction<
          Void Function(
              Pointer<NativeFunction<GgmlLogCallbackNative>>, Pointer<Void>),
          void Function(Pointer<NativeFunction<GgmlLogCallbackNative>>,
              Pointer<Void>)>('llama_log_set'),
      modelDefaultParams: lib.lookupFunction<LlamaModelParams Function(),
          LlamaModelParams Function()>('llama_model_default_params'),
      contextDefaultParams: lib.lookupFunction<LlamaContextParams Function(),
          LlamaContextParams Function()>('llama_context_default_params'),
      modelLoadFromFile: lib.lookupFunction<
          Pointer<Void> Function(Pointer<Uint8>, LlamaModelParams),
          Pointer<Void> Function(Pointer<Uint8>,
              LlamaModelParams)>('llama_model_load_from_file'),
      modelFree: lib.lookupFunction<Void Function(Pointer<Void>),
          void Function(Pointer<Void>)>('llama_model_free'),
      initFromModel: lib.lookupFunction<
          Pointer<Void> Function(Pointer<Void>, LlamaContextParams),
          Pointer<Void> Function(
              Pointer<Void>, LlamaContextParams)>('llama_init_from_model'),
      contextFree: lib.lookupFunction<Void Function(Pointer<Void>),
          void Function(Pointer<Void>)>('llama_free'),
      nCtx: lib.lookupFunction<Uint32 Function(Pointer<Void>),
          int Function(Pointer<Void>)>('llama_n_ctx'),
      modelGetVocab: lib.lookupFunction<Pointer<Void> Function(Pointer<Void>),
          Pointer<Void> Function(Pointer<Void>)>('llama_model_get_vocab'),
      tokenize: lib.lookupFunction<
          Int32 Function(Pointer<Void>, Pointer<Uint8>, Int32, Pointer<Int32>,
              Int32, Bool, Bool),
          int Function(Pointer<Void>, Pointer<Uint8>, int, Pointer<Int32>,
              int, bool, bool)>('llama_tokenize'),
      tokenToPiece: lib.lookupFunction<
          Int32 Function(
              Pointer<Void>, Int32, Pointer<Uint8>, Int32, Int32, Bool),
          int Function(Pointer<Void>, int, Pointer<Uint8>, int, int,
              bool)>('llama_token_to_piece'),
      vocabIsEog: lib.lookupFunction<Bool Function(Pointer<Void>, Int32),
          bool Function(Pointer<Void>, int)>('llama_vocab_is_eog'),
      batchGetOne: lib.lookupFunction<
          LlamaBatch Function(Pointer<Int32>, Int32),
          LlamaBatch Function(Pointer<Int32>, int)>('llama_batch_get_one'),
      decode: lib.lookupFunction<Int32 Function(Pointer<Void>, LlamaBatch),
          int Function(Pointer<Void>, LlamaBatch)>('llama_decode'),
      samplerInitGreedy: lib.lookupFunction<Pointer<Void> Function(),
          Pointer<Void> Function()>('llama_sampler_init_greedy'),
      samplerFree: lib.lookupFunction<Void Function(Pointer<Void>),
          void Function(Pointer<Void>)>('llama_sampler_free'),
      samplerSample: lib.lookupFunction<
          Int32 Function(Pointer<Void>, Pointer<Void>, Int32),
          int Function(
              Pointer<Void>, Pointer<Void>, int)>('llama_sampler_sample'),
      stateSeqGetSize: lib.lookupFunction<Size Function(Pointer<Void>, Int32),
          int Function(Pointer<Void>, int)>('llama_state_seq_get_size'),
      stateSeqGetData: lib.lookupFunction<
          Size Function(Pointer<Void>, Pointer<Uint8>, Size, Int32),
          int Function(Pointer<Void>, Pointer<Uint8>, int,
              int)>('llama_state_seq_get_data'),
      stateSeqSetData: lib.lookupFunction<
          Size Function(Pointer<Void>, Pointer<Uint8>, Size, Int32),
          int Function(Pointer<Void>, Pointer<Uint8>, int,
              int)>('llama_state_seq_set_data'),
      getMemory: lib.lookupFunction<Pointer<Void> Function(Pointer<Void>),
          Pointer<Void> Function(Pointer<Void>)>('llama_get_memory'),
      memorySeqRm: lib.lookupFunction<
          Bool Function(Pointer<Void>, Int32, Int32, Int32),
          bool Function(
              Pointer<Void>, int, int, int)>('llama_memory_seq_rm'),
      memorySeqPosMax: lib.lookupFunction<
          Int32 Function(Pointer<Void>, Int32),
          int Function(Pointer<Void>, int)>('llama_memory_seq_pos_max'),
    );
  }
}
