import 'dart:async';
import 'dart:math' as math;

import 'model_capabilities.dart';
import 'model_request.dart';
import 'model_response.dart';
import 'retry_policy.dart';
import 'vaster_model_interface.dart';

/// One retry/fallback decision, reported through [ResilientVasterModel.onRetry].
class ModelRetryEvent {
  /// Model the failed attempt ran against.
  final String modelName;

  /// 1-based attempt number on that model.
  final int attempt;

  final Object error;

  /// Backoff before the next attempt; `null` when switching models or giving up.
  final Duration? nextDelay;

  /// True when the failure moves execution to the next fallback model.
  final bool switchingModel;

  const ModelRetryEvent({
    required this.modelName,
    required this.attempt,
    required this.error,
    this.nextDelay,
    this.switchingModel = false,
  });

  @override
  String toString() =>
      'retry(model=$modelName attempt=$attempt error=$error '
      '${switchingModel ? 'FALLBACK' : 'delay=${nextDelay?.inMilliseconds}ms'})';
}

/// Default transient-error classifier for LLM boundaries.
///
/// Transient (worth retrying the same model): timeouts, connection-level
/// failures, and retryable HTTP statuses — 408 (request timeout), 429 (rate
/// limit), 5xx, and 529 (Anthropic overloaded). Everything else — 400s, auth,
/// schema violations — is permanent for that model (a fallback model may
/// still be tried).
bool defaultIsTransient(Object error) {
  if (error is TimeoutException) return true;

  // Connection-level failures, matched structurally so this package stays
  // free of dart:io / package:http dependencies.
  final typeName = error.runtimeType.toString();
  if (typeName.contains('SocketException') ||
      typeName.contains('ClientException') ||
      typeName.contains('HandshakeException') ||
      typeName.contains('HttpException')) {
    return true;
  }

  // HTTP status embedded in the error text (backends throw
  // `StateError('Claude API error 429 ...')`-style messages).
  final match = RegExp(r'\b(4\d\d|5\d\d)\b').firstMatch('$error');
  if (match != null) {
    final status = int.parse(match.group(1)!);
    return status == 408 || status == 429 || (status >= 500 && status < 600);
  }
  return false;
}

/// A [VasterModel] decorator that adds retry with exponential backoff,
/// per-attempt timeouts, and a fallback model chain to any backend.
///
/// Attempt order: [primary] up to [RetryPolicy.maxAttempts] times (transient
/// errors only), then each model in [fallbacks] the same way. Non-transient
/// errors skip remaining retries on the current model — the same request will
/// keep failing — but still advance to the next fallback, which may be a
/// different provider entirely. When every model is exhausted the last error
/// rethrows.
///
/// Streaming: retry/fallback applies only until the first chunk is emitted.
/// A mid-stream failure surfaces to the caller — chunks already delivered
/// cannot be safely un-sent or re-spliced.
class ResilientVasterModel implements VasterModel {
  final VasterModel primary;
  final List<VasterModel> fallbacks;
  final RetryPolicy retryPolicy;

  /// Classifies an error as transient (retry same model) or permanent
  /// (advance to the next model). Defaults to [defaultIsTransient].
  final bool Function(Object error) isTransient;

  /// Observer for every retry/fallback decision (logging, metrics).
  final void Function(ModelRetryEvent event)? onRetry;

  /// Injectable delay for tests; defaults to [Future.delayed].
  final Future<void> Function(Duration delay) _sleep;

  /// Injectable randomness for deterministic backoff in tests.
  final math.Random? random;

  ResilientVasterModel({
    required this.primary,
    this.fallbacks = const [],
    this.retryPolicy = const RetryPolicy(),
    this.isTransient = defaultIsTransient,
    this.onRetry,
    Future<void> Function(Duration delay)? sleep,
    this.random,
  }) : _sleep = sleep ?? _defaultSleep;

  static Future<void> _defaultSleep(Duration delay) => Future.delayed(delay);

  List<VasterModel> get _chain => [primary, ...fallbacks];

  @override
  String get modelName => primary.modelName;

  @override
  ModelCapabilities get capabilities => primary.capabilities;

  @override
  Future<ModelResponse> generate(ModelRequest request) async {
    Object? lastError;
    StackTrace? lastStack;

    final chain = _chain;
    for (var m = 0; m < chain.length; m++) {
      final model = chain[m];
      final isLastModel = m == chain.length - 1;

      for (var attempt = 1; attempt <= retryPolicy.maxAttempts; attempt++) {
        try {
          return await _withTimeout(model.generate(request));
        } catch (e, st) {
          lastError = e;
          lastStack = st;

          final transient = isTransient(e);
          final retriesLeft = attempt < retryPolicy.maxAttempts;

          if (transient && retriesLeft) {
            final delay = retryPolicy.backoffFor(attempt, random: random);
            onRetry?.call(ModelRetryEvent(
              modelName: model.modelName,
              attempt: attempt,
              error: e,
              nextDelay: delay,
            ));
            await _sleep(delay);
            continue;
          }

          // Permanent error or retries exhausted: advance to next model.
          if (!isLastModel) {
            onRetry?.call(ModelRetryEvent(
              modelName: model.modelName,
              attempt: attempt,
              error: e,
              switchingModel: true,
            ));
          }
          break;
        }
      }
    }

    Error.throwWithStackTrace(lastError!, lastStack!);
  }

  @override
  Stream<ModelResponseChunk> generateStream(ModelRequest request) async* {
    Object? lastError;
    StackTrace? lastStack;

    final chain = _chain;
    for (var m = 0; m < chain.length; m++) {
      final model = chain[m];
      final isLastModel = m == chain.length - 1;

      for (var attempt = 1; attempt <= retryPolicy.maxAttempts; attempt++) {
        var emitted = false;
        try {
          await for (final chunk in model.generateStream(request)) {
            emitted = true;
            yield chunk;
          }
          return;
        } catch (e, st) {
          if (emitted) rethrow; // mid-stream: chunks already delivered

          lastError = e;
          lastStack = st;

          final transient = isTransient(e);
          final retriesLeft = attempt < retryPolicy.maxAttempts;

          if (transient && retriesLeft) {
            final delay = retryPolicy.backoffFor(attempt, random: random);
            onRetry?.call(ModelRetryEvent(
              modelName: model.modelName,
              attempt: attempt,
              error: e,
              nextDelay: delay,
            ));
            await _sleep(delay);
            continue;
          }

          if (!isLastModel) {
            onRetry?.call(ModelRetryEvent(
              modelName: model.modelName,
              attempt: attempt,
              error: e,
              switchingModel: true,
            ));
          }
          break;
        }
      }
    }

    Error.throwWithStackTrace(lastError!, lastStack!);
  }

  Future<ModelResponse> _withTimeout(Future<ModelResponse> future) {
    final timeout = retryPolicy.attemptTimeout;
    return timeout == null ? future : future.timeout(timeout);
  }
}
