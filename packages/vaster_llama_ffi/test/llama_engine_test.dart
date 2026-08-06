@Tags(['llama'])
library;

import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:test/test.dart';
import 'package:vaster_kv/vaster_kv.dart';
import 'package:vaster_llama_ffi/vaster_llama_ffi.dart';
import 'package:vaster_mmap/vaster_mmap.dart';

/// Real-inference engine tests on the CI-tier model (stories15M, ~18MB).
///
/// Skipped with a clear message when the model or libllama is absent, so
/// the suite degrades gracefully on machines without the ZC-P0 setup.
void main() {
  final modelPath = Platform.environment['VASTER_LLAMA_TEST_MODEL'] ??
      '${Platform.environment['HOME']}/models/stories15M-q4_0.gguf';
  final available = File(modelPath).existsSync() &&
      File(LlamaBindings.defaultLibraryPath).existsSync();
  final skip = available
      ? null
      : 'needs $modelPath and ${LlamaBindings.defaultLibraryPath} '
          '(see docs/ZERO_COPY.md setup)';

  group('LlamaEngine (sync, real inference)', () {
    late LlamaEngine engine;

    setUp(() => engine = LlamaEngine.load(modelPath: modelPath));
    tearDown(() => engine.dispose());

    test('tokenize/detokenize round-trips through the real vocab', () {
      final tokens = engine.tokenize('Once upon a time');
      expect(tokens, isNotEmpty);
      final text =
          tokens.skip(1).map(engine.pieceOf).join(); // skip BOS
      expect(text.trim(), startsWith('Once'));
    });

    test('greedy generation is deterministic across engines', () {
      final a = engine.generateText('Once upon a time', maxTokens: 12);
      final other = LlamaEngine.load(modelPath: modelPath);
      addTearDown(other.dispose);
      final b = other.generateText('Once upon a time', maxTokens: 12);
      expect(a, isNotEmpty);
      expect(a, b, reason: 'CPU + 1 thread + greedy must be reproducible');
    });

    test('export → import into a FRESH engine continues token-identically',
        () {
      engine.prefill(engine.tokenize('Once upon a time'));
      final next = engine.sampleGreedy();
      final state = engine.exportState();
      expect(state.length, engine.stateSize);

      final restored = LlamaEngine.load(modelPath: modelPath);
      addTearDown(restored.dispose);
      restored.importState(state);
      expect(restored.tokensDecoded, engine.tokensDecoded,
          reason: 'token count re-derived from restored memory');

      engine.decodeOne(next);
      restored.decodeOne(next);
      expect(restored.sampleGreedy(), engine.sampleGreedy(),
          reason: 'the KV state, not a cold start, produced the logits');
    });

    test('export writes DIRECTLY into shared frame pages and restores from '
        'an attachment', () {
      engine.prefill(engine.tokenize('The little dog'));
      final size = engine.stateSize;
      final name =
          'vaster_llama_kv_test_${DateTime.now().microsecondsSinceEpoch}';
      final frame = SharedMemoryFrame.allocate(name,
          payloadLength: size, meta: engine.tokensDecoded);
      addTearDown(() => frame.close(unlink: true));

      final written = engine.exportStateInto(frame.payloadPointer, size);
      expect(written, size, reason: 'exact-size frame, fully written');

      final attachment = SharedMemoryFrame.attach(name);
      addTearDown(attachment.close);
      final restored = LlamaEngine.load(modelPath: modelPath);
      addTearDown(restored.dispose);
      restored.importStateFrom(
          attachment.payloadPointer, attachment.payloadLength);
      expect(restored.tokensDecoded, attachment.meta,
          reason: 'meta carries the token count');

      // Logits don't ride with KV state: sampling first is a typed error…
      expect(restored.sampleGreedy, throwsStateError);

      // …and after decoding the same continuation token, the restored
      // engine's logits come from the shared-page state, not a cold start.
      final next = engine.sampleGreedy();
      engine.decodeOne(next);
      restored.decodeOne(next);
      expect(restored.sampleGreedy(), engine.sampleGreedy());
    });

    test('a garbage blob raises the typed incompatible-state error', () {
      final restored = LlamaEngine.load(modelPath: modelPath);
      addTearDown(restored.dispose);
      expect(
          () => restored.importState(
              Uint8List.fromList(List<int>.generate(512, (i) => i % 251))),
          throwsA(isA<LlamaStateIncompatibleException>()));
    });

    test('continueFromImage: validated reuse and the exact-cover case', () {
      const prefixText = 'Once upon a time';
      final prefixTokens = engine.tokenize(prefixText);
      engine.prefill(prefixTokens);
      final image = _exportImage(engine, prefixTokens, 'fp-engine-a');
      addTearDown(image.free);

      // Full validation chain, remainder decoded, count exact.
      final restored = LlamaEngine.load(modelPath: modelPath);
      addTearDown(restored.dispose);
      final fullTokens =
          restored.tokenize('$prefixText there was a dog');
      final reuse = restored.continueFromImage(
          image: image.image,
          statePointer: image.statePointer,
          promptTokens: fullTokens);
      expect(reuse, isA<KvReuseValidated>());
      expect((reuse as KvReuseValidated).reusedTokens, prefixTokens.length);
      expect(restored.tokensDecoded, fullTokens.length);

      // Correctness: identical next token to the uninterrupted engine.
      engine.prefill(
          Int32List.sublistView(fullTokens, prefixTokens.length));
      expect(restored.sampleGreedy(), engine.sampleGreedy(),
          reason: 'validated reuse must equal a cold decode');

      // Exact cover: prompt == prefix — the tail token is re-decoded so
      // logits exist, and exactly one token of reuse is given up.
      final covered = LlamaEngine.load(modelPath: modelPath);
      addTearDown(covered.dispose);
      final reuseCover = covered.continueFromImage(
          image: image.image,
          statePointer: image.statePointer,
          promptTokens: prefixTokens);
      expect((reuseCover as KvReuseValidated).reusedTokens,
          prefixTokens.length - 1);
      expect(covered.sampleGreedy(), isNonNegative,
          reason: 'logits are ready after the tail re-decode');
    });

    test('continueFromImage rejects a diverging prompt and decodes cold',
        () {
      final prefixTokens = engine.tokenize('Once upon a time');
      engine.prefill(prefixTokens);
      final image = _exportImage(engine, prefixTokens, 'fp-engine-b');
      addTearDown(image.free);

      final other = LlamaEngine.load(modelPath: modelPath);
      addTearDown(other.dispose);
      final divergent = other.tokenize('A completely different story');
      final reuse = other.continueFromImage(
          image: image.image,
          statePointer: image.statePointer,
          promptTokens: divergent);
      expect(reuse, isA<KvReuseRejected>());
      final rejected = reuse as KvReuseRejected;
      expect(rejected.reason, 'prefix-mismatch');
      expect(rejected.divergenceIndex, isNotNull);
      expect(other.tokensDecoded, divergent.length,
          reason: 'rejection cold-decodes the full prompt — the caller '
              'always ends with correct logits');
      expect(other.sampleGreedy(), isNonNegative);

      // A prompt SHORTER than the prefix diverges at its own length.
      final shorter = LlamaEngine.load(modelPath: modelPath);
      addTearDown(shorter.dispose);
      final shortTokens = shorter.tokenize('Once upon');
      final shortReuse = shorter.continueFromImage(
          image: image.image,
          statePointer: image.statePointer,
          promptTokens: shortTokens) as KvReuseRejected;
      expect(shortReuse.divergenceIndex, shortTokens.length);
      expect(shorter.tokensDecoded, shortTokens.length);
    });

    test('continueFromImage rejects a foreign engineTag before any restore',
        () {
      final prefixTokens = engine.tokenize('Once upon a time');
      engine.prefill(prefixTokens);
      final image = _exportImage(engine, prefixTokens, 'fp-engine-c',
          engineTag: engine.engineTag ^ 0xDEAD); // a different producer
      addTearDown(image.free);

      final other = LlamaEngine.load(modelPath: modelPath);
      addTearDown(other.dispose);
      final prompt = other.tokenize('Once upon a time there was a dog');
      final reuse = other.continueFromImage(
          image: image.image,
          statePointer: image.statePointer,
          promptTokens: prompt) as KvReuseRejected;
      expect(reuse.reason, 'engine-tag-mismatch');
      expect(other.tokensDecoded, prompt.length, reason: 'cold decode');
    });

    test('generateSteps is the one loop generateText delegates to', () {
      engine.prefill(engine.tokenize('Once upon a time'));
      final (text, generated, _) = engine.generateSteps(maxTokens: 8);
      expect(generated, greaterThan(0));

      final other = LlamaEngine.load(modelPath: modelPath);
      addTearDown(other.dispose);
      expect(other.generateText('Once upon a time', maxTokens: 8), text,
          reason: 'same prompt, same loop, same greedy tokens');
    });

    test('reset clears the sequence for a fresh prefill', () {
      engine.prefill(engine.tokenize('Once upon a time'));
      expect(engine.tokensDecoded, greaterThan(0));
      engine.reset();
      expect(engine.tokensDecoded, 0);
      expect(engine.generateText('The cat', maxTokens: 4), isNotEmpty);
    });
  }, skip: skip);

  group('adversarial reuse (PV-P3)', () {
    late LlamaEngine engine;
    setUp(() => engine = LlamaEngine.load(modelPath: modelPath));
    tearDown(() => engine.dispose());

    test('BPE seam re-merging is caught: content ending mid-word', () {
      // 'Once upon a t' tokenizes its tail as a fragment; in the full
      // prompt the same characters belong to ' time'. String-prefix
      // checking would pass this — token-exact validation must not.
      final seamTokens = engine.tokenize('Once upon a t');
      engine.prefill(seamTokens);
      final image = _exportImage(engine, seamTokens, 'fp-seam');
      addTearDown(image.free);

      final other = LlamaEngine.load(modelPath: modelPath);
      addTearDown(other.dispose);
      final fullTokens = other.tokenize('Once upon a time there was a dog');
      expect('Once upon a time'.startsWith('Once upon a t'), isTrue,
          reason: 'the STRING is a prefix — that is exactly the trap');

      final reuse = other.continueFromImage(
          image: image.image,
          statePointer: image.statePointer,
          promptTokens: fullTokens);
      expect(reuse, isA<KvReuseRejected>(),
          reason: 'the token streams diverge at the seam even though the '
              'strings agree');
      expect((reuse as KvReuseRejected).reason, 'prefix-mismatch');
      expect(other.tokensDecoded, fullTokens.length, reason: 'cold decode');
    });

    test('cross-model reuse is rejected by engineTag before any restore',
        () {
      final smolPath =
          '${Platform.environment['HOME']}/models/SmolLM2-135M-Instruct-Q4_K_M.gguf';
      if (!File(smolPath).existsSync()) {
        markTestSkipped('needs $smolPath (ZC-P0 demo tier)');
        return;
      }
      // Materialize under stories15M…
      final prefixTokens = engine.tokenize('Once upon a time');
      engine.prefill(prefixTokens);
      final image = _exportImage(engine, prefixTokens, 'fp-crossmodel');
      addTearDown(image.free);

      // …and attempt reuse under a DIFFERENT model. Restoring foreign
      // state would be garbage even where tokenizers happened to agree;
      // the tag rejects before the engine ever sees the state bytes.
      final smol = LlamaEngine.load(modelPath: smolPath);
      addTearDown(smol.dispose);
      expect(smol.engineTag, isNot(engine.engineTag));
      final prompt = smol.tokenize('Once upon a time there was a dog');
      final reuse = smol.continueFromImage(
          image: image.image,
          statePointer: image.statePointer,
          promptTokens: prompt) as KvReuseRejected;
      expect(reuse.reason, 'engine-tag-mismatch');
      expect(smol.tokensDecoded, prompt.length, reason: 'cold decode');
    });
  }, skip: skip);

  group('LlamaWorker (isolate host)', () {
    test('generates off the main isolate and round-trips state via a frame',
        () async {
      final worker = await LlamaWorker.spawn(modelPath: modelPath);
      final text = await worker.generate('Once upon a time', maxTokens: 8);
      expect(text, isNotEmpty);

      final name =
          'vaster_llama_worker_test_${DateTime.now().microsecondsSinceEpoch}';
      final (bytes, tokens) = await worker.materializeToFrame(
          content: 'Once upon a time',
          contentFingerprint: 'fp-worker-roundtrip',
          frameName: name);
      expect(bytes, greaterThan(0));
      expect(tokens, greaterThan(0));
      await worker.close();

      // A brand-new worker — fresh isolate, fresh engine — resumes from
      // the frame alone.
      final second = await LlamaWorker.spawn(modelPath: modelPath);
      final restoredTokens = await second.importStateFromFrame(name);
      expect(restoredTokens, tokens);
      // Non-empty continuation prompt: logits are not part of exported
      // state, so the restored context must decode before it can sample.
      final continuation = await second.generate(' and', maxTokens: 6);
      expect(continuation, isNotEmpty,
          reason: 'generation continues from restored KV state');
      await second.close();

      SharedMemoryFrame.attach(name).close(unlink: true); // evict
    });

    test('model-load failure surfaces as the spawn error', () async {
      await expectLater(
          LlamaWorker.spawn(modelPath: '/nonexistent/model.gguf'),
          throwsStateError);
    });
  }, skip: skip);
}

/// A [KvStateImage] over a native, 8-aligned buffer, with [engine]'s
/// current sequence state exported in place at the image's state offset
/// — the same shape a frame payload has, without the shm container.
final class _NativeImage {
  final KvStateImage image;
  final Pointer<Uint8> _base;
  _NativeImage(this.image, this._base);
  Pointer<Uint8> get statePointer =>
      Pointer<Uint8>.fromAddress(_base.address + image.stateOffset);
  void free() => calloc.free(_base);
}

_NativeImage _exportImage(
    LlamaEngine engine, Int32List tokens, String fingerprint,
    {int? engineTag}) {
  final stateSize = engine.stateSize;
  final total = KvStateImage.layoutSize(
      contentFingerprint: fingerprint,
      tokenCount: tokens.length,
      stateSize: stateSize);
  final base = calloc<Uint8>(total);
  final image = KvStateImage.initialize(base.asTypedList(total),
      tokenIds: tokens,
      contentFingerprint: fingerprint,
      engineTag: engineTag ?? engine.engineTag,
      stateSize: stateSize);
  engine.exportStateInto(
      Pointer<Uint8>.fromAddress(base.address + image.stateOffset),
      stateSize);
  return _NativeImage(image, base);
}
