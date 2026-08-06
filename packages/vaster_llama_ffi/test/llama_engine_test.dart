@Tags(['llama'])
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
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

    test('prefillContinuation reuses a restored prefix, decodes the rest',
        () {
      const full = 'Once upon a time there was a dog';
      engine.prefill(engine.tokenize('Once upon a time'));
      final restoredPrefix = engine.tokensDecoded;

      final (promptTokens, reused) = engine.prefillContinuation(full);
      expect(reused, restoredPrefix,
          reason: 'the existing prefix was not re-decoded');
      expect(promptTokens, engine.tokensDecoded,
          reason: 'the remainder was decoded to exactly the prompt length');

      // Exact cover: the prompt equals the sequence — the tail token is
      // re-decoded (logits do not travel with KV state), nothing else.
      final (again, reusedAgain) = engine.prefillContinuation(full);
      expect(again, promptTokens);
      expect(reusedAgain, promptTokens - 1);

      // Impossible reuse: a shorter prompt cannot reuse a longer prefix —
      // cold decode, never wrong-position decoding.
      final (shortTokens, shortReused) =
          engine.prefillContinuation('Once upon');
      expect(shortReused, 0);
      expect(engine.tokensDecoded, shortTokens);
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

  group('LlamaWorker (isolate host)', () {
    test('generates off the main isolate and round-trips state via a frame',
        () async {
      final worker = await LlamaWorker.spawn(modelPath: modelPath);
      final text = await worker.generate('Once upon a time', maxTokens: 8);
      expect(text, isNotEmpty);

      final name =
          'vaster_llama_worker_test_${DateTime.now().microsecondsSinceEpoch}';
      final (bytes, tokens) = await worker.exportStateToFrame(name);
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
