import 'package:test/test.dart';
import 'package:vaster_model/vaster_model.dart';

/// Bring-your-own-model: the caller's own invocation wrapped as a
/// [VasterModel], with the machine's semantics (resilience, cancellation,
/// streaming contract) composing exactly as for shipped backends.
void main() {
  ModelRequest requestWith({CancellationToken? cancelToken}) => ModelRequest(
    messages: [ChatMessage.user('turn one'), ChatMessage.user('turn two')],
    generationConfig: const GenerationConfig(),
    cancelToken: cancelToken,
  );

  group('fromHandler (full tier):', () {
    test('the handler sees the COMPLETE request and owns the response', () async {
      ModelRequest? seen;
      final token = CancellationToken();
      final model = VasterModel.fromHandler((request) async {
        seen = request;
        return ModelResponse(
          message: ChatMessage.model('HANDLER-ANSWER'),
          finishReason: FinishReason.stop,
          usage: const UsageMetadata(
            promptTokenCount: 11,
            candidatesTokenCount: 7,
            source: UsageSource.measured,
          ),
        );
      }, modelName: 'my-proxy');

      final response = await model.generate(requestWith(cancelToken: token));

      expect(seen!.messages, hasLength(2), reason: 'full history, not a flattened prompt');
      expect(identical(seen!.cancelToken, token), isTrue, reason: 'cancellation rides the request');
      expect(response.message.text, 'HANDLER-ANSWER');
      expect(response.usage.promptTokenCount, 11, reason: 'REAL usage flows through untouched');
      expect(model.modelName, 'my-proxy');
      expect(model.capabilities.maxContextTokens, HandlerVasterModel.defaultCapabilities.maxContextTokens);
    });

    test('default stream synthesis: one terminal chunk, cumulative usage', () async {
      final model = VasterModel.fromHandler(
        (request) async => ModelResponse(
          message: ChatMessage.model('FULL-TEXT'),
          finishReason: FinishReason.stop,
          usage: UsageMetadata(candidatesTokenCount: 3),
        ),
      );
      final chunks = await model.generateStream(requestWith()).toList();
      expect(chunks, hasLength(1));
      expect(chunks.single.textDelta, 'FULL-TEXT');
      expect(chunks.single.finishReason, FinishReason.stop);
      expect(chunks.single.usage!.candidatesTokenCount, 3);
    });

    test('a custom stream handler wins over synthesis', () async {
      final model = VasterModel.fromHandler(
        (request) async => throw StateError('generate must not be called'),
        onGenerateStream: (request) => Stream.fromIterable(const [
          ModelResponseChunk(textDelta: 'A'),
          ModelResponseChunk(textDelta: 'B', finishReason: FinishReason.stop),
        ]),
      );
      final chunks = await model.generateStream(requestWith()).toList();
      expect(chunks.map((c) => c.textDelta), ['A', 'B']);
    });
  });

  group('fromTextHandler (text tier):', () {
    test('same request in, text out, default usage for the estimation path', () async {
      ModelRequest? seen;
      final model = VasterModel.fromTextHandler((request) async {
        seen = request;
        return 'plain text answer';
      }, modelName: 'my-fn');

      final response = await model.generate(requestWith());
      expect(seen!.messages, hasLength(2), reason: 'nothing silently dropped');
      expect(response.message.text, 'plain text answer');
      expect(response.finishReason, FinishReason.stop);
      expect(response.usage.totalTokenCount, 0, reason: 'no fabricated numbers — metering estimates');
    });
  });

  group('composition:', () {
    test('resilience wraps a handler like any backend: transient retries, then serves', () async {
      var attempts = 0;
      final resilient = ResilientVasterModel(
        primary: VasterModel.fromHandler((request) async {
          attempts++;
          if (attempts < 3) throw StateError('backend error 503 unavailable');
          return ModelResponse(message: ChatMessage.model('THIRD-TIME'));
        }),
        retryPolicy: const RetryPolicy(maxAttempts: 3, initialBackoff: Duration.zero),
        sleep: (_) async {},
      );
      final response = await resilient.generate(requestWith());
      expect(response.message.text, 'THIRD-TIME');
      expect(attempts, 3);
    });

    test('cancellation is the caller\'s decision — never retried', () async {
      var attempts = 0;
      final resilient = ResilientVasterModel(
        primary: VasterModel.fromHandler((request) async {
          attempts++;
          request.cancelToken?.throwIfCancelled();
          return ModelResponse(message: ChatMessage.model('unreachable'));
        }),
        retryPolicy: const RetryPolicy(maxAttempts: 3, initialBackoff: Duration.zero),
        sleep: (_) async {},
      );
      final token = CancellationToken()..cancel('user closed the sheet');
      await expectLater(
        resilient.generate(requestWith(cancelToken: token)),
        throwsA(isA<CancelledException>()),
      );
      expect(attempts, 1, reason: 'CancelledException rethrows immediately');
    });
  });
}
