import 'dart:async';
import 'dart:ffi';
import 'dart:isolate';

import 'package:vaster_kv/vaster_kv.dart';
import 'package:vaster_mmap/vaster_mmap.dart';

import 'bindings/llama_bindings.dart';
import 'llama_engine.dart';

const _imageCodec = KvStateImageCodec();

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

  /// Greedily generates from the current logits. Returns
  /// `(text, generatedTokens, hitLimit)` — [hitLimit] when [maxTokens] or
  /// the context window stopped generation rather than end-of-generation.
  Future<(String, int, bool)> generateSteps({int maxTokens = 64}) async {
    final r =
        (await _request('generateSteps', {'maxTokens': maxTokens}))! as List;
    return (r[0] as String, r[1] as int, r[2] as bool);
  }

  /// **Atomic** materialize: reset → decode [content] → write a
  /// `KvStateImage` (header, [contentFingerprint], the decoded token
  /// ids, then engine state at the image's state offset) into the frame
  /// named [frameName], as ONE mailbox operation — no other request can
  /// interleave and poison the published frame. Returns
  /// `(imageBytes, tokenCount)`.
  Future<(int, int)> materializeToFrame(
      {required String content,
      required String contentFingerprint,
      required String frameName}) async {
    final r = (await _request('materialize', {
      'text': content,
      'fingerprint': contentFingerprint,
      'frame': frameName,
    }))! as List;
    return (r[0] as int, r[1] as int);
  }

  /// **Atomic** full generation: reset → validated state reuse from
  /// [restoreFrame] (spec §Consuming — every rejection decodes cold
  /// inside the same operation) → greedy generation, as ONE mailbox
  /// operation. Returns `(promptTokens, reuse, generatedText,
  /// generatedTokens, hitLimit)` — [KvReuse] is the sealed account of
  /// what happened to the reuse attempt.
  Future<(int, KvReuse, String, int, bool)> runGenerate({
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
      KvReuse.fromJson(r[1] as Map<Object?, Object?>),
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

  /// The engine's KV-state producer identity (spec §engineTag).
  Future<int> engineTag() async =>
      await _request('engineTag', const {}) as int;

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
    case 'generateSteps':
      final (text, generated, hitLimit) =
          engine.generateSteps(maxTokens: request['maxTokens']! as int);
      return [text, generated, hitLimit];
    case 'materialize':
      // Atomic at the mailbox: nothing interleaves between reset, decode
      // and publish, so the published content-addressed frame can never
      // hold state from a half-finished neighbor operation. The frame's
      // payload is a KvStateImage: header + fingerprint + the decoded
      // token ids (validation ground truth), with engine state exported
      // in place at the image's state offset — the zero-copy path.
      engine.reset();
      final tokens = engine.tokenize(request['text']! as String);
      engine.prefill(tokens);
      final fingerprint = request['fingerprint']! as String;
      final stateSize = engine.stateSize;
      final imageBytes = _imageCodec.layoutSize(
          contentFingerprint: fingerprint,
          tokenCount: tokens.length,
          stateSize: stateSize);
      final frame = SharedMemoryFrame.allocate(request['frame']! as String,
          payloadLength: imageBytes, meta: tokens.length);
      try {
        if (frame.isOwner) {
          final image = _imageCodec.initialize(frame.bytes,
              tokenIds: tokens,
              contentFingerprint: fingerprint,
              engineTag: engine.engineTag,
              stateSize: stateSize);
          engine.exportStateInto(
              Pointer<Uint8>.fromAddress(
                  frame.payloadPointer.address + image.stateOffset),
              stateSize);
        }
        return [imageBytes, tokens.length];
      } finally {
        frame.close(unlink: false);
      }
    case 'runGenerate':
      // Atomic at the mailbox: validated reuse → generate as one
      // operation, so a concurrent materialize cannot corrupt the
      // sequence mid-generation (or vice versa). The worker only handles
      // the CONTAINER (attach, parse, pointer math); the reuse policy —
      // tag check, token-exact prefix validation, restore, remainder —
      // is the engine's continueFromImage (Rule 10.3/10.4).
      final promptTokens =
          engine.tokenize(request['text']! as String);
      var reuse = const KvReuseNone() as KvReuse;
      final restoreFrame = request['restoreFrame'] as String?;
      var restored = false;
      if (restoreFrame != null) {
        try {
          final attached = SharedMemoryFrame.attach(restoreFrame);
          try {
            final image = _imageCodec.parse(attached.bytes);
            reuse = engine.continueFromImage(
              image: image,
              statePointer: Pointer<Uint8>.fromAddress(
                  attached.payloadPointer.address + image.stateOffset),
              promptTokens: promptTokens,
            );
          } on KvStateImageFormatException {
            reuse = const KvReuseRejected('invalid-image');
          } on KvStateImageAlignmentException {
            reuse = const KvReuseRejected('invalid-image');
          } finally {
            attached.close(unlink: false);
          }
        } on StateError {
          // Frame vanished between lookup and attach — cold decode.
          reuse = const KvReuseRejected('invalid-image');
        }
      }
      if (!restored) {
        engine.reset();
        engine.prefill(promptTokens);
      }
      final (text, generated, hitLimit) =
          engine.generateSteps(maxTokens: request['maxTokens']! as int);
      return [promptTokens.length, reuse.toJson(), text, generated, hitLimit];
    case 'importState':
      // Restores from a frame's KvStateImage; the caller (controller
      // restore) owns the decision — but producer identity is still
      // checked, and a mismatch is the typed incompatible-state error.
      final frame = SharedMemoryFrame.attach(request['frame']! as String);
      try {
        final image = _imageCodec.parse(frame.bytes);
        if (image.engineTag != engine.engineTag) {
          throw LlamaStateIncompatibleException(
              'image engineTag 0x${image.engineTag.toRadixString(16)} does '
              'not match this engine — different build or model.');
        }
        engine.importStateFrom(
            Pointer<Uint8>.fromAddress(
                frame.payloadPointer.address + image.stateOffset),
            image.stateSize);
        return engine.tokensDecoded;
      } finally {
        frame.close(unlink: false);
      }
    case 'reset':
      engine.reset();
      return null;
    case 'tokensDecoded':
      return engine.tokensDecoded;
    case 'engineTag':
      return engine.engineTag;
    case 'dispose':
      engine.dispose();
      return null;
    default:
      throw StateError('Unknown worker op "${request['op']}".');
  }
}
