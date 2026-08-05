import 'dart:async';
import 'dart:isolate';

import 'package:vaster_mmap/vaster_mmap.dart';

import 'bindings/llama_bindings.dart';
import 'llama_engine.dart';

/// Async facade over a [LlamaEngine] living in a dedicated worker isolate.
///
/// `llama_decode` is a blocking native call; hosting the engine in its own
/// isolate keeps the VM's event loop (scheduler, event bus, HITL gates)
/// responsive while inference runs on a real parallel thread.
///
/// KV state never crosses the isolate boundary: [exportStateToFrame] and
/// [importStateFromFrame] name a [SharedMemoryFrame], and the worker moves
/// state directly between the engine and the frame's mapped pages on its
/// side — the message channel carries only names and counts.
final class LlamaWorker {
  final Isolate _isolate;
  final SendPort _commands;
  final ReceivePort _responses;
  final Map<int, Completer<Object?>> _pending;
  int _nextRequestId = 0;
  bool _closed = false;

  LlamaWorker._(this._isolate, this._commands, this._responses, this._pending);

  /// Spawns the worker and loads the model inside it. Completes when the
  /// engine is ready (or throws the load failure verbatim).
  static Future<LlamaWorker> spawn({
    required String modelPath,
    String libraryPath = LlamaBindings.defaultLibraryPath,
    int contextLength = 2048,
    int batchSize = 512,
    int threads = 1,
    int gpuLayers = 0,
  }) async {
    final responses = ReceivePort();
    final ready = Completer<SendPort>();
    final pending = <int, Completer<Object?>>{};

    responses.listen((message) {
      if (message is SendPort) {
        ready.complete(message);
        return;
      }
      final envelope = message as Map<Object?, Object?>;
      if (!ready.isCompleted) {
        // Engine construction failed before the command port existed.
        ready.completeError(
            StateError(envelope['error']! as String), StackTrace.current);
        return;
      }
      final completer = pending.remove(envelope['id'] as int)!;
      final error = envelope['error'] as String?;
      if (error == null) {
        completer.complete(envelope['result']);
      } else if (envelope['stateIncompatible'] == true) {
        completer.completeError(LlamaStateIncompatibleException(error));
      } else {
        completer.completeError(StateError(error));
      }
    });

    final Isolate isolate;
    try {
      isolate = await Isolate.spawn(
        _workerMain,
        _WorkerConfig(
          replyTo: responses.sendPort,
          modelPath: modelPath,
          libraryPath: libraryPath,
          contextLength: contextLength,
          batchSize: batchSize,
          threads: threads,
          gpuLayers: gpuLayers,
        ),
        debugName: 'llama-worker',
      );
    } on Object {
      responses.close(); // unwind: an unclosed port pins this isolate alive
      rethrow;
    }

    final SendPort commands;
    try {
      commands = await ready.future;
    } on Object {
      responses.close();
      isolate.kill(priority: Isolate.immediate);
      rethrow;
    }

    return LlamaWorker._(isolate, commands, responses, pending);
  }

  /// Prefills [prompt] and greedily generates up to [maxTokens] tokens.
  Future<String> generate(String prompt, {int maxTokens = 64}) async =>
      await _request('generate',
          {'prompt': prompt, 'maxTokens': maxTokens}) as String;

  Future<List<int>> tokenize(String text) async =>
      ((await _request('tokenize', {'text': text})) as List).cast<int>();

  /// Tokenizes and decodes [text] into the sequence as-is (no reuse
  /// logic). Returns the token count decoded.
  Future<int> decodeText(String text) async =>
      await _request('decodeText', {'text': text}) as int;

  /// Prefills [text], reusing whatever prefix the sequence already holds
  /// (a restored KV state): tokens `[0, tokensDecoded)` are assumed to be
  /// the restored prefix and only the remainder is decoded. Returns
  /// `(promptTokens, reusedTokens)`. With an empty sequence this is a
  /// plain full prefill (`reusedTokens == 0`).
  Future<(int, int)> prefillContinuation(String text) async {
    final r = (await _request('prefillContinuation', {'text': text}))! as List;
    return (r[0] as int, r[1] as int);
  }

  /// Greedily generates from the current logits. Returns
  /// `(text, generatedTokens, hitLimit)` — [hitLimit] when [maxTokens] or
  /// the context window stopped generation rather than end-of-generation.
  Future<(String, int, bool)> generateSteps({int maxTokens = 64}) async {
    final r =
        (await _request('generateSteps', {'maxTokens': maxTokens}))! as List;
    return (r[0] as String, r[1] as int, r[2] as bool);
  }

  /// Exports sequence state directly into a shared-memory frame named
  /// [frameName] (created at exact state size; `meta` holds the token
  /// count). Returns `(stateBytes, tokenCount)`.
  Future<(int, int)> exportStateToFrame(String frameName) async {
    final r =
        (await _request('exportState', {'frame': frameName}))! as List;
    return (r[0] as int, r[1] as int);
  }

  /// **Atomic** materialize: reset → decode [content] → export state into
  /// the frame named [frameName], as ONE mailbox operation — no other
  /// request can interleave and poison the published frame. Returns
  /// `(stateBytes, tokenCount)`.
  Future<(int, int)> materializeToFrame(
      {required String content, required String frameName}) async {
    final r = (await _request(
        'materialize', {'text': content, 'frame': frameName}))! as List;
    return (r[0] as int, r[1] as int);
  }

  /// **Atomic** full generation: reset → optional state restore from
  /// [restoreFrame] → continuation prefill of [text] → greedy generation,
  /// as ONE mailbox operation. An incompatible frame degrades to a cold
  /// decode inside the same operation. Returns
  /// `(promptTokens, reusedTokens, generatedText, generatedTokens,
  /// hitLimit)`.
  Future<(int, int, String, int, bool)> runGenerate({
    required String text,
    required int maxTokens,
    String? restoreFrame,
  }) async {
    final r = (await _request('runGenerate', {
      'text': text,
      'maxTokens': maxTokens,
      'restoreFrame': restoreFrame,
    }))! as List;
    return (
      r[0] as int,
      r[1] as int,
      r[2] as String,
      r[3] as int,
      r[4] as bool
    );
  }

  /// Restores sequence state from the frame named [frameName]. Returns the
  /// restored token count. Throws [LlamaStateIncompatibleException] when
  /// the engine rejects the blob.
  Future<int> importStateFromFrame(String frameName) async =>
      await _request('importState', {'frame': frameName}) as int;

  /// Clears the sequence.
  Future<void> reset() => _request('reset', const {});

  /// Tokens currently decoded into the sequence.
  Future<int> tokensDecoded() async =>
      await _request('tokensDecoded', const {}) as int;

  /// Disposes the engine and tears the isolate down.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    try {
      await _request('dispose', const {});
    } finally {
      _responses.close();
      _isolate.kill(priority: Isolate.beforeNextEvent);
      for (final completer in _pending.values) {
        completer.completeError(StateError('LlamaWorker closed.'));
      }
      _pending.clear();
    }
  }

  Future<Object?> _request(String op, Map<String, Object?> args) {
    if (_closed && op != 'dispose') {
      throw StateError('LlamaWorker is closed.');
    }
    final id = _nextRequestId++;
    final completer = Completer<Object?>();
    _pending[id] = completer;
    _commands.send({'id': id, 'op': op, ...args});
    return completer.future;
  }
}

final class _WorkerConfig {
  final SendPort replyTo;
  final String modelPath;
  final String libraryPath;
  final int contextLength;
  final int batchSize;
  final int threads;
  final int gpuLayers;

  const _WorkerConfig({
    required this.replyTo,
    required this.modelPath,
    required this.libraryPath,
    required this.contextLength,
    required this.batchSize,
    required this.threads,
    required this.gpuLayers,
  });
}

void _workerMain(_WorkerConfig config) {
  final LlamaEngine engine;
  try {
    engine = LlamaEngine.load(
      modelPath: config.modelPath,
      libraryPath: config.libraryPath,
      contextLength: config.contextLength,
      batchSize: config.batchSize,
      threads: config.threads,
      gpuLayers: config.gpuLayers,
    );
  } on Object catch (e) {
    config.replyTo.send({'error': e.toString()});
    return;
  }

  final commands = ReceivePort();
  config.replyTo.send(commands.sendPort);

  commands.listen((message) {
    final request = message as Map<Object?, Object?>;
    final id = request['id'] as int;
    try {
      final result = _dispatch(engine, request);
      config.replyTo.send({'id': id, 'result': result});
      if (request['op'] == 'dispose') commands.close();
    } on LlamaStateIncompatibleException catch (e) {
      config.replyTo
          .send({'id': id, 'error': e.message, 'stateIncompatible': true});
    } on Object catch (e) {
      config.replyTo.send({'id': id, 'error': e.toString()});
    }
  });
}

Object? _dispatch(LlamaEngine engine, Map<Object?, Object?> request) {
  switch (request['op']) {
    case 'generate':
      return engine.generateText(request['prompt']! as String,
          maxTokens: request['maxTokens']! as int);
    case 'tokenize':
      return engine.tokenize(request['text']! as String);
    case 'decodeText':
      final tokens = engine.tokenize(request['text']! as String);
      engine.prefill(tokens);
      return tokens.length;
    case 'prefillContinuation':
      final (promptTokens, reused) =
          _prefillContinuation(engine, request['text']! as String);
      return [promptTokens, reused];
    case 'generateSteps':
      final (text, generated, hitLimit) =
          _generateSteps(engine, request['maxTokens']! as int);
      return [text, generated, hitLimit];
    case 'materialize':
      // Atomic at the mailbox: nothing interleaves between reset, decode
      // and export, so the published content-addressed frame can never
      // hold state from a half-finished neighbor operation.
      engine.reset();
      engine.prefill(engine.tokenize(request['text']! as String));
      final frame = SharedMemoryFrame.allocate(request['frame']! as String,
          payloadLength: engine.stateSize, meta: engine.tokensDecoded);
      try {
        if (frame.isOwner) {
          engine.exportStateInto(frame.payloadPointer, frame.payloadLength);
        }
        return [frame.payloadLength, engine.tokensDecoded];
      } finally {
        frame.close(unlink: false);
      }
    case 'runGenerate':
      // Atomic at the mailbox: restore → continuation prefill → generate
      // as one operation, so a concurrent materialize cannot corrupt the
      // sequence mid-generation (or vice versa).
      engine.reset();
      final restoreFrame = request['restoreFrame'] as String?;
      if (restoreFrame != null) {
        try {
          final attached = SharedMemoryFrame.attach(restoreFrame);
          try {
            engine.importStateFrom(
                attached.payloadPointer, attached.payloadLength);
          } finally {
            attached.close(unlink: false);
          }
        } on LlamaStateIncompatibleException {
          engine.reset(); // stale build/model — degrade to a cold decode
        } on StateError {
          // Frame vanished between lookup and attach — cold decode.
        }
      }
      final (promptTokens, reused) =
          _prefillContinuation(engine, request['text']! as String);
      final (text, generated, hitLimit) =
          _generateSteps(engine, request['maxTokens']! as int);
      return [promptTokens, reused, text, generated, hitLimit];
    case 'exportState':
      final frameName = request['frame']! as String;
      final size = engine.stateSize;
      final frame = SharedMemoryFrame.allocate(frameName,
          payloadLength: size, meta: engine.tokensDecoded);
      try {
        if (frame.isOwner) {
          engine.exportStateInto(frame.payloadPointer, size);
        }
        return [size, engine.tokensDecoded];
      } finally {
        frame.close(unlink: false); // content-at-rest: stays discoverable
      }
    case 'importState':
      final frame = SharedMemoryFrame.attach(request['frame']! as String);
      try {
        engine.importStateFrom(frame.payloadPointer, frame.payloadLength);
        return engine.tokensDecoded;
      } finally {
        frame.close(unlink: false);
      }
    case 'reset':
      engine.reset();
      return null;
    case 'tokensDecoded':
      return engine.tokensDecoded;
    case 'dispose':
      engine.dispose();
      return null;
    default:
      throw StateError('Unknown worker op "${request['op']}".');
  }
}

/// Continuation prefill: tokens `[0, tokensDecoded)` are the (restored)
/// prefix; only the remainder is decoded. Handles the impossible-reuse
/// case (restored prefix longer than the prompt → cold) and the
/// exact-cover case (re-decode the tail token — logits don't travel with
/// KV state). Returns `(promptTokens, reusedTokens)`.
(int, int) _prefillContinuation(LlamaEngine engine, String text) {
  final all = engine.tokenize(text);
  var reused = engine.tokensDecoded;
  if (reused > all.length) {
    engine.reset();
    reused = 0;
  }
  if (reused == all.length && reused > 0) {
    engine.dropTail(1);
    reused = engine.tokensDecoded;
  }
  engine.prefill(all.sublist(engine.tokensDecoded));
  return (all.length, reused);
}

/// Greedy generation from the current logits. Returns
/// `(text, generatedTokens, hitLimit)`.
(String, int, bool) _generateSteps(LlamaEngine engine, int maxTokens) {
  final out = StringBuffer();
  var generated = 0;
  var hitLimit = true; // loop exits without a break == limit reached
  for (var i = 0; i < maxTokens; i++) {
    final token = engine.sampleGreedy();
    if (engine.isEndOfGeneration(token)) {
      hitLimit = false;
      break;
    }
    out.write(engine.pieceOf(token));
    generated++;
    if (engine.tokensDecoded >= engine.contextLength) break;
    engine.decodeOne(token);
  }
  return (out.toString(), generated, hitLimit);
}
