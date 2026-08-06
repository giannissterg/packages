import 'dart:async';

import 'package:test/test.dart';
import 'package:vaster_model/vaster_model.dart';
import 'package:vaster_model_fake/vaster_model_fake.dart';

void main() {
  ModelRequest request() =>
      ModelRequest(messages: [ChatMessage.user('hello')]);

  /// A fake that fails the first [failures] calls with [error], then succeeds.
  FakeVasterModel flaky(int failures, Object Function() error,
      {String name = 'flaky', String reply = 'ok'}) {
    var calls = 0;
    return FakeVasterModel(
      modelName: name,
      handler: (req) {
        calls++;
        if (calls <= failures) throw error();
        return ModelResponse(
          message: ChatMessage.model(reply),
          finishReason: FinishReason.stop,
          usage: const UsageMetadata(
              promptTokenCount: 1, candidatesTokenCount: 1),
        );
      },
    );
  }

  /// No-op sleep so tests don't wait out real backoff delays.
  Future<void> noSleep(Duration _) async {}

  group('defaultIsTransient', () {
    test('classifies retryable statuses and timeouts as transient', () {
      expect(defaultIsTransient(TimeoutException('slow')), isTrue);
      expect(defaultIsTransient(StateError('Claude API error 429 rate')),
          isTrue);
      expect(defaultIsTransient(StateError('Claude API error 503 busy')),
          isTrue);
      expect(
          defaultIsTransient(StateError('Claude API error 529 overloaded')),
          isTrue);
    });

    test('classifies client errors and auth as permanent', () {
      expect(defaultIsTransient(StateError('Claude API error 400 bad')),
          isFalse);
      expect(defaultIsTransient(StateError('Claude API error 401 auth')),
          isFalse);
      expect(defaultIsTransient(ArgumentError('bad schema')), isFalse);
    });
  });

  group('RetryPolicy backoff', () {
    test('grows exponentially and caps at maxBackoff', () {
      const policy = RetryPolicy(
        initialBackoff: Duration(milliseconds: 100),
        backoffMultiplier: 2,
        maxBackoff: Duration(milliseconds: 350),
        jitter: 0,
      );
      expect(policy.backoffFor(1), const Duration(milliseconds: 100));
      expect(policy.backoffFor(2), const Duration(milliseconds: 200));
      expect(policy.backoffFor(3), const Duration(milliseconds: 350)); // capped
      expect(policy.backoffFor(9), const Duration(milliseconds: 350));
    });
  });

  group('ResilientVasterModel.generate', () {
    test('retries transient failures and succeeds within budget', () async {
      final model = ResilientVasterModel(
        primary: flaky(2, () => StateError('API error 429 rate limited')),
        retryPolicy: const RetryPolicy(maxAttempts: 3),
        sleep: noSleep,
      );
      final response = await model.generate(request());
      expect(response.text, 'ok');
    });

    test('gives up after maxAttempts and rethrows the last error', () async {
      final model = ResilientVasterModel(
        primary: flaky(99, () => StateError('API error 503')),
        retryPolicy: const RetryPolicy(maxAttempts: 3),
        sleep: noSleep,
      );
      await expectLater(model.generate(request()), throwsStateError);
    });

    test('permanent errors do not retry the same model', () async {
      final primary = flaky(99, () => StateError('API error 400 bad request'),
          name: 'primary');
      final model = ResilientVasterModel(
        primary: primary,
        retryPolicy: const RetryPolicy(maxAttempts: 5),
        sleep: noSleep,
      );
      await expectLater(model.generate(request()), throwsStateError);
      expect(primary.recordedRequests, hasLength(1),
          reason: 'a 400 will fail identically on every retry');
    });

    test('falls back to the next model after primary exhausts', () async {
      final primary =
          flaky(99, () => StateError('API error 500'), name: 'primary');
      final backup = flaky(0, () => StateError('unused'),
          name: 'backup', reply: 'from backup');
      final events = <ModelRetryEvent>[];

      final model = ResilientVasterModel(
        primary: primary,
        fallbacks: [backup],
        retryPolicy: const RetryPolicy(maxAttempts: 2),
        sleep: noSleep,
        onRetry: events.add,
      );

      final response = await model.generate(request());
      expect(response.text, 'from backup');
      expect(primary.recordedRequests, hasLength(2));
      expect(backup.recordedRequests, hasLength(1));

      // One backoff retry on primary, then one fallback switch.
      expect(events.where((e) => !e.switchingModel), hasLength(1));
      expect(events.where((e) => e.switchingModel), hasLength(1));
      expect(events.last.modelName, 'primary');
    });

    test('permanent error still advances to a fallback provider', () async {
      final primary =
          flaky(99, () => StateError('API error 401 bad key'), name: 'primary');
      final backup =
          flaky(0, () => StateError(''), name: 'backup', reply: 'rescued');
      final model = ResilientVasterModel(
        primary: primary,
        fallbacks: [backup],
        sleep: noSleep,
      );
      final response = await model.generate(request());
      expect(response.text, 'rescued');
      expect(primary.recordedRequests, hasLength(1));
    });

    test('stamps servedBy with the member that actually served', () async {
      final primary =
          flaky(99, () => StateError('API error 500'), name: 'primary');
      final backup = flaky(0, () => StateError('unused'),
          name: 'backup', reply: 'from backup');

      final chained = ResilientVasterModel(
        primary: primary,
        fallbacks: [backup],
        retryPolicy: const RetryPolicy(maxAttempts: 1),
        sleep: noSleep,
      );
      expect((await chained.generate(request())).servedBy, 'backup');

      final healthy = ResilientVasterModel(
        primary: flaky(0, () => StateError('unused'), name: 'primary'),
        retryPolicy: const RetryPolicy(maxAttempts: 1),
        sleep: noSleep,
      );
      expect((await healthy.generate(request())).servedBy, 'primary');
    });

    test('cancellation is a decision, not a model failure — never advances',
        () async {
      final primary = FakeVasterModel(
        modelName: 'primary',
        handler: (req) => throw const CancelledException('caller cancelled'),
      );
      final backup = flaky(0, () => StateError('unused'),
          name: 'backup', reply: 'must never serve');
      final model = ResilientVasterModel(
        primary: primary,
        fallbacks: [backup],
        retryPolicy: const RetryPolicy(maxAttempts: 3),
        sleep: noSleep,
      );
      await expectLater(
          model.generate(request()), throwsA(isA<CancelledException>()));
      expect(primary.recordedRequests, hasLength(1),
          reason: 'cancellation must not be retried');
      expect(backup.recordedRequests, isEmpty,
          reason: 'cancellation must not advance the chain');
    });

    test('per-attempt timeout converts a hang into a retry', () async {
      var calls = 0;
      final hanging = FakeVasterModel(
        modelName: 'hanging',
        handler: (req) async {
          calls++;
          if (calls == 1) {
            await Future<void>.delayed(const Duration(seconds: 30));
          }
          return ModelResponse(
            message: ChatMessage.model('finally'),
            finishReason: FinishReason.stop,
            usage: const UsageMetadata(
                promptTokenCount: 1, candidatesTokenCount: 1),
          );
        },
      );
      final model = ResilientVasterModel(
        primary: hanging,
        retryPolicy: const RetryPolicy(
          maxAttempts: 2,
          attemptTimeout: Duration(milliseconds: 50),
        ),
        sleep: noSleep,
      );
      final response = await model.generate(request());
      expect(response.text, 'finally');
      expect(calls, 2);
    });
  });

  group('ResilientVasterModel.generateStream', () {
    test('retries a stream that fails before the first chunk', () async {
      var calls = 0;
      final model = ResilientVasterModel(
        primary: FakeVasterModel(
          modelName: 'stream-flaky',
          handler: (req) {
            calls++;
            if (calls == 1) throw StateError('API error 503');
            return ModelResponse(
              message: ChatMessage.model('streamed ok'),
              finishReason: FinishReason.stop,
              usage: const UsageMetadata(
                  promptTokenCount: 1, candidatesTokenCount: 1),
            );
          },
        ),
        retryPolicy: const RetryPolicy(maxAttempts: 2),
        sleep: noSleep,
      );

      final chunks = await model.generateStream(request()).toList();
      expect(chunks, isNotEmpty);
      expect(calls, greaterThanOrEqualTo(2));
    });
  });
}
