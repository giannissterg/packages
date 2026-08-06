@Tags(['llama'])
library;

import 'dart:io';

import 'package:test/test.dart';
import 'package:vaster_llama_ffi/vaster_llama_ffi.dart';
import 'package:vaster_model/vaster_model.dart';

/// ZC-P3: the VasterModel + KV controller layer on real inference.
void main() {
  final modelPath = Platform.environment['VASTER_LLAMA_TEST_MODEL'] ??
      '${Platform.environment['HOME']}/models/stories15M-q4_0.gguf';
  final available = File(modelPath).existsSync() &&
      File(LlamaBindings.defaultLibraryPath).existsSync();
  final skip = available
      ? null
      : 'needs $modelPath and ${LlamaBindings.defaultLibraryPath} '
          '(see docs/ZERO_COPY.md setup)';

  const pinnedKnowledge =
      'Once upon a time there was a little dog named Bo.\n';
  const fingerprint =
      'test-fp-0123456789abcdef0123456789abcdef'; // caller-supplied hash

  group('LlamaFfiKvCacheController', () {
    late LlamaWorker worker;
    late LlamaFfiKvCacheController kv;

    setUp(() async {
      worker = await LlamaWorker.spawn(modelPath: modelPath);
      kv = LlamaFfiKvCacheController(
          worker: worker,
          namePrefix:
              'vkvt_${DateTime.now().microsecondsSinceEpoch % 100000}_');
    });
    tearDown(() async {
      for (final handle in await kv.list()) {
        await kv.evict(handle);
      }
      await worker.close();
    });

    test('materialize → cross-controller lookup → restore → evict', () async {
      final handle = await kv.materialize(
          contentFingerprint: fingerprint, content: pinnedKnowledge);
      expect(handle.tokenCount, greaterThan(0));
      expect(handle.sizeBytes, greaterThan(0));
      expect(handle.backend, 'llama-ffi');

      // A SECOND controller with no local memory — as a fresh process
      // would be — discovers the frame by fingerprint alone.
      final foreign =
          LlamaFfiKvCacheController(worker: worker, namePrefix: kv.namePrefix);
      final found = await foreign.lookup(fingerprint);
      expect(found, isNotNull);
      expect(found!.tokenCount, handle.tokenCount);
      expect(found.sizeBytes, handle.sizeBytes);

      await worker.reset();
      await kv.restore(handle);
      expect(await worker.tokensDecoded(), handle.tokenCount);

      await kv.evict(handle);
      expect(await foreign.lookup('never-materialized'), isNull);
    });

    test('materialize is idempotent per fingerprint', () async {
      final first = await kv.materialize(
          contentFingerprint: fingerprint, content: pinnedKnowledge);
      final second = await kv.materialize(
          contentFingerprint: fingerprint, content: pinnedKnowledge);
      expect(second.handleId, first.handleId);
      expect(second.tokenCount, first.tokenCount);
    });
  }, skip: skip);

  group('LlamaFfiVasterModel', () {
    late LlamaWorker worker;
    late LlamaFfiKvCacheController kv;
    late LlamaFfiVasterModel model;

    setUp(() async {
      worker = await LlamaWorker.spawn(modelPath: modelPath);
      kv = LlamaFfiKvCacheController(
          worker: worker,
          namePrefix:
              'vkvm_${DateTime.now().microsecondsSinceEpoch % 100000}_');
      model = LlamaFfiVasterModel(worker: worker, frameResolver: kv);
    });
    tearDown(() async {
      for (final handle in await kv.list()) {
        await kv.evict(handle);
      }
      await worker.close();
    });

    ModelRequest request({List<ContextCacheHint> hints = const []}) =>
        ModelRequest(
          systemInstruction: ChatMessage.system(pinnedKnowledge),
          messages: [ChatMessage.user('What was the dog called?')],
          generationConfig: const GenerationConfig(maxOutputTokens: 16),
          cacheHints: hints,
        );

    test('cold call: measured usage, no cache reads', () async {
      final response = await model.generate(request());
      expect(response.text, isNotEmpty);
      expect(response.usage.source, UsageSource.measured);
      expect(response.usage.promptTokenCount, greaterThan(0));
      expect(response.usage.cacheReadTokenCount, 0);
    });

    test('warm call restores KV from the frame and matches cold output',
        () async {
      final cold = await model.generate(request());

      // Materialize the system prefix, then call again WITH the hint.
      // composePrompt renders the system instruction first, so the
      // materialized content is a true prompt prefix.
      final content = '$pinnedKnowledge\n';
      final handle = await kv.materialize(
          contentFingerprint: fingerprint, content: content);
      final warm = await model.generate(request(hints: [
        ContextCacheHint(
            regionId: 'knowledge', contentFingerprint: fingerprint),
      ]));

      expect(warm.usage.cacheReadTokenCount, handle.tokenCount,
          reason: 'the restored prefix was not re-decoded');
      expect(warm.usage.promptTokenCount, cold.usage.promptTokenCount,
          reason: 'same prompt, same total — reuse changes cost, not size');
      expect(warm.text, cold.text,
          reason: 'KV state from shared pages must be equivalent to a '
              'cold decode — the zero-copy correctness property');
    });

    test('a hint nobody materialized falls back to a cold decode', () async {
      final response = await model.generate(request(hints: [
        ContextCacheHint(
            regionId: 'ghost', contentFingerprint: 'fp-that-never-was'),
      ]));
      expect(response.text, isNotEmpty);
      expect(response.usage.cacheReadTokenCount, 0);
    });

    test('single-chunk stream carries final usage', () async {
      final chunks = await model.generateStream(request()).toList();
      expect(chunks, hasLength(1));
      expect(chunks.single.usage, isNotNull);
      expect(chunks.single.textDelta, isNotEmpty);
    });
  }, skip: skip);
}
