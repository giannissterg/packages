import 'dart:math' as math;

/// Retry behavior for a model boundary: how many attempts, how long to back
/// off between them, and how long a single attempt may run.
class RetryPolicy {
  /// Total attempts per model, including the first (1 = no retries).
  final int maxAttempts;

  /// Backoff before the second attempt; doubles (times [backoffMultiplier])
  /// on each subsequent one.
  final Duration initialBackoff;

  final double backoffMultiplier;

  /// Upper bound on any single backoff delay.
  final Duration maxBackoff;

  /// Fraction of the computed delay randomized away (0..1). Jitter decorrelates
  /// retry storms when many callers fail at once.
  final double jitter;

  /// Wall-clock limit per attempt; `null` disables the per-attempt timeout.
  final Duration? attemptTimeout;

  const RetryPolicy({
    this.maxAttempts = 3,
    this.initialBackoff = const Duration(milliseconds: 500),
    this.backoffMultiplier = 2.0,
    this.maxBackoff = const Duration(seconds: 30),
    this.jitter = 0.25,
    this.attemptTimeout,
  })  : assert(maxAttempts >= 1),
        assert(jitter >= 0 && jitter <= 1);

  /// A policy that never retries and never times out.
  static const none = RetryPolicy(maxAttempts: 1);

  /// Delay before retry number [retry] (1-based: the delay after the first
  /// failure is `backoffFor(1)`). Exponential with full-jitter subtraction.
  Duration backoffFor(int retry, {math.Random? random}) {
    final exponent = retry - 1;
    var millis = initialBackoff.inMilliseconds *
        math.pow(backoffMultiplier, exponent).toDouble();
    millis = math.min(millis, maxBackoff.inMilliseconds.toDouble());
    if (jitter > 0) {
      final rng = random ?? _sharedRandom;
      millis -= millis * jitter * rng.nextDouble();
    }
    return Duration(milliseconds: millis.round());
  }

  static final _sharedRandom = math.Random();
}
