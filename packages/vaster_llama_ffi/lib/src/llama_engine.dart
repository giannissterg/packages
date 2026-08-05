import 'dart:convert';
import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'bindings/llama_bindings.dart';

/// Restoring sequence state failed — the blob is from an incompatible
/// llama.cpp build, a different model, or is corrupt. Surfaced as typed
/// data (never a silent cold start): the caller decides whether to
/// re-prefill.
final class LlamaStateIncompatibleException implements Exception {
  final String message;
  LlamaStateIncompatibleException(this.message);
  @override
  String toString() => 'LlamaStateIncompatibleException: $message';
}

/// A synchronous, deterministic llama.cpp inference engine over one model
/// and one context (sequence 0).
///
/// Blocking by design — `llama_decode` is a synchronous native call. Hosts
/// that must not stall an event loop run the engine inside a worker
/// isolate ([LlamaWorker]); the engine itself stays single-threaded and
/// simple.
///
/// Determinism recipe (the ZC-P0 probe's): CPU-only ([gpuLayers] 0),
/// [threads] 1, greedy sampling. With those, continuations are
/// token-identical across state export/import — the property the
/// zero-copy KV tests assert.
///
/// The full collaborator graph (model, context, vocab, sampler, memory
/// handle) is built eagerly in [LlamaEngine.load]; every failure path
/// frees exactly the native resources it had acquired.
final class LlamaEngine {
  final LlamaBindings _b;
  final Pointer<Void> _model;
  final Pointer<Void> _context;
  final Pointer<Void> _vocab;
  final Pointer<Void> _sampler;
  final Pointer<Void> _memory;

  /// Logical batch size — prompts longer than this are prefilled in
  /// chunks.
  final int batchSize;

  /// Context window (tokens) this engine was created with.
  final int contextLength;

  int _tokensDecoded = 0;
  bool _logitsReady = false;
  bool _disposed = false;

  LlamaEngine._(this._b, this._model, this._context, this._vocab,
      this._sampler, this._memory,
      {required this.batchSize, required this.contextLength});

  /// Loads [modelPath] and builds a ready engine. CPU-only and
  /// single-threaded by default (see the determinism recipe above).
  factory LlamaEngine.load({
    required String modelPath,
    String libraryPath = LlamaBindings.defaultLibraryPath,
    int contextLength = 2048,
    int batchSize = 512,
    int threads = 1,
    int gpuLayers = 0,
  }) {
    final b = LlamaBindings.open(libraryPath: libraryPath);

    // Silence ggml's stderr firehose before anything can log — a
    // process-global native no-op, never a Dart trampoline (see
    // [LlamaBindings.silenceLogs] for why).
    b.silenceLogs();
    b.backendInit();

    final mp = b.modelDefaultParams()..nGpuLayers = gpuLayers;
    final cPath = _cString(modelPath);
    final Pointer<Void> model;
    try {
      model = b.modelLoadFromFile(cPath, mp);
    } finally {
      calloc.free(cPath);
    }
    if (model == nullptr) {
      throw StateError('llama.cpp could not load model "$modelPath".');
    }

    final cp = b.contextDefaultParams()
      ..nCtx = contextLength
      ..nBatch = batchSize
      ..nThreads = threads
      ..nThreadsBatch = threads;
    final context = b.initFromModel(model, cp);
    if (context == nullptr) {
      b.modelFree(model);
      throw StateError('llama.cpp could not create a context '
          '(n_ctx=$contextLength) for "$modelPath".');
    }

    return LlamaEngine._(b, model, context, b.modelGetVocab(model),
        b.samplerInitGreedy(), b.getMemory(context),
        batchSize: batchSize, contextLength: contextLength);
  }

  /// Tokens decoded into sequence 0 so far (prompt + generated). After
  /// [importState] this is re-derived from the restored memory itself.
  int get tokensDecoded => _tokensDecoded;

  /// Tokenizes [text]. [addBos] prepends the model's BOS token — use it
  /// for the start of a sequence, not for continuations.
  List<int> tokenize(String text, {bool addBos = true}) {
    _checkLive();
    final bytes = utf8.encode(text);
    final cText = _cString(text);
    final capacity = bytes.length + 16;
    final tokens = calloc<Int32>(capacity);
    try {
      final n = _b.tokenize(
          _vocab, cText, bytes.length, tokens, capacity, addBos, false);
      if (n < 0) {
        throw StateError('tokenize needed ${-n} slots for $capacity-slot '
            'buffer — text/vocab mismatch.');
      }
      return [for (var i = 0; i < n; i++) tokens[i]];
    } finally {
      calloc.free(cText);
      calloc.free(tokens);
    }
  }

  /// The text of one token id.
  String pieceOf(int token) {
    _checkLive();
    final buf = calloc<Uint8>(256);
    try {
      final n = _b.tokenToPiece(_vocab, token, buf, 256, 0, true);
      if (n <= 0) return '';
      return utf8.decode([for (var i = 0; i < n; i++) buf[i]],
          allowMalformed: true);
    } finally {
      calloc.free(buf);
    }
  }

  /// True when [token] ends generation (EOS/EOT family).
  bool isEndOfGeneration(int token) {
    _checkLive();
    return _b.vocabIsEog(_vocab, token);
  }

  /// Decodes [tokens] into sequence 0, chunked by [batchSize]. After this
  /// the last token's logits are current — [sampleGreedy] continues from
  /// here.
  void prefill(List<int> tokens) {
    _checkLive();
    if (tokens.isEmpty) return;
    if (_tokensDecoded + tokens.length > contextLength) {
      throw StateError('prefill of ${tokens.length} tokens would exceed '
          'n_ctx=$contextLength (already at $_tokensDecoded).');
    }
    final buf = calloc<Int32>(tokens.length);
    try {
      for (var i = 0; i < tokens.length; i++) {
        buf[i] = tokens[i];
      }
      var offset = 0;
      while (offset < tokens.length) {
        final n = (tokens.length - offset).clamp(0, batchSize);
        final rc = _b.decode(_context,
            _b.batchGetOne(Pointer<Int32>.fromAddress(buf.address + offset * 4), n));
        if (rc != 0) {
          throw StateError('llama_decode failed (rc=$rc) at offset $offset.');
        }
        offset += n;
        _tokensDecoded += n;
      }
      _logitsReady = true;
    } finally {
      calloc.free(buf);
    }
  }

  /// Greedy-samples the next token from the current logits.
  ///
  /// Requires a preceding [prefill]/[decodeOne] **in this context**:
  /// logits are not part of exported state, so a freshly restored engine
  /// must decode at least one token before sampling. Guarded here as a
  /// typed error — natively it is a process-killing assert.
  int sampleGreedy() {
    _checkLive();
    if (!_logitsReady) {
      throw StateError('no logits in this context yet — decode before '
          'sampling (logits are not part of exported KV state).');
    }
    return _b.samplerSample(_sampler, _context, -1);
  }

  /// Decodes a single [token] (a sampled continuation step).
  void decodeOne(int token) => prefill([token]);

  /// Convenience loop: prefill [prompt] (BOS-prefixed when the sequence is
  /// empty), then greedily generate up to [maxTokens] tokens, stopping at
  /// end-of-generation. Returns the generated text.
  String generateText(String prompt, {int maxTokens = 64}) {
    _checkLive();
    prefill(tokenize(prompt, addBos: _tokensDecoded == 0));
    final out = StringBuffer();
    for (var i = 0; i < maxTokens; i++) {
      final token = sampleGreedy();
      if (isEndOfGeneration(token)) break;
      out.write(pieceOf(token));
      if (_tokensDecoded >= contextLength) break;
      decodeOne(token);
    }
    return out.toString();
  }

  /// Exact byte size of sequence 0's exportable state right now.
  int get stateSize {
    _checkLive();
    return _b.stateSeqGetSize(_context, 0);
  }

  /// Writes sequence 0's state into [destination] (native memory, e.g. a
  /// `SharedMemoryFrame.payloadPointer` — the zero-copy path). Returns
  /// bytes written. [capacity] guards the destination's length.
  int exportStateInto(Pointer<Uint8> destination, int capacity) {
    _checkLive();
    final needed = stateSize;
    if (needed > capacity) {
      throw ArgumentError('state needs $needed bytes; destination holds '
          '$capacity.');
    }
    final written = _b.stateSeqGetData(_context, destination, capacity, 0);
    if (written == 0) {
      throw StateError('llama_state_seq_get_data wrote 0 bytes.');
    }
    return written;
  }

  /// Convenience heap export (tests, non-shm transports).
  Uint8List exportState() {
    final size = stateSize;
    final buf = calloc<Uint8>(size);
    try {
      final written = exportStateInto(buf, size);
      return Uint8List.fromList(buf.asTypedList(written));
    } finally {
      calloc.free(buf);
    }
  }

  /// Restores sequence 0 from [length] bytes at [source] (native memory,
  /// e.g. an attached frame's `payloadPointer`), replacing whatever the
  /// sequence held. Token count is re-derived from the restored memory.
  /// Throws [LlamaStateIncompatibleException] when llama.cpp rejects the
  /// blob (its internal versioning is the compatibility authority).
  void importStateFrom(Pointer<Uint8> source, int length) {
    _checkLive();
    reset();
    final consumed = _b.stateSeqSetData(_context, source, length, 0);
    if (consumed == 0) {
      throw LlamaStateIncompatibleException(
          'llama_state_seq_set_data rejected a $length-byte blob — '
          'incompatible build, different model, or corrupt state.');
    }
    _tokensDecoded = _b.memorySeqPosMax(_memory, 0) + 1;
    // Logits do not travel with KV state — the next sample needs a decode.
    _logitsReady = false;
  }

  /// Heap-buffer variant of [importStateFrom].
  void importState(Uint8List state) {
    final buf = calloc<Uint8>(state.length);
    try {
      buf.asTypedList(state.length).setAll(0, state);
      importStateFrom(buf, state.length);
    } finally {
      calloc.free(buf);
    }
  }

  /// Clears sequence 0 — an empty context, ready for a fresh prefill.
  void reset() {
    _checkLive();
    _b.memorySeqRm(_memory, 0, -1, -1);
    _tokensDecoded = 0;
    _logitsReady = false;
  }

  /// Frees every native resource. Idempotent.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _b.samplerFree(_sampler);
    _b.contextFree(_context);
    _b.modelFree(_model);
  }

  void _checkLive() {
    if (_disposed) throw StateError('LlamaEngine has been disposed.');
  }

  static Pointer<Uint8> _cString(String s) {
    final units = utf8.encode(s);
    final buf = calloc<Uint8>(units.length + 1);
    buf.asTypedList(units.length).setAll(0, units);
    buf[units.length] = 0;
    return buf;
  }
}
