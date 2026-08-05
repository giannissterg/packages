import 'package:vaster_runtime/vaster_runtime.dart';

import 'scorer.dart';

/// One trial's full record: outcome, score, and the real metered numbers.
final class TrialResult {
  final int trial;
  final RuntimeStatus status;
  final ScoreResult score;
  final Object? resultValue;
  final int consumedTokens;
  final double consumedCostUsd;
  final Duration wallClock;
  final String? errorDetails;

  const TrialResult({
    required this.trial,
    required this.status,
    required this.score,
    required this.resultValue,
    required this.consumedTokens,
    required this.consumedCostUsd,
    required this.wallClock,
    required this.errorDetails,
  });

  Map<String, dynamic> toJson() => {
        'trial': trial,
        'status': status.name,
        'score': score.toJson(),
        if (resultValue != null) 'result': '$resultValue',
        'tokens': consumedTokens,
        'costUsd': consumedCostUsd,
        'wallClockMs': wallClock.inMilliseconds,
        if (errorDetails != null) 'error': errorDetails,
      };
}

/// One variant's aggregate over its trials.
final class VariantReport {
  final String variant;
  final List<TrialResult> trials;

  const VariantReport({required this.variant, required this.trials});

  int get trialCount => trials.length;

  /// Trials whose composite score passed (== 1.0).
  int get passed => trials.where((t) => t.score.passed).length;

  double get successRate => trialCount == 0 ? 0 : passed / trialCount;

  double get meanScore => trialCount == 0
      ? 0
      : trials.fold(0.0, (s, t) => s + t.score.value) / trialCount;

  int get totalTokens => trials.fold(0, (s, t) => s + t.consumedTokens);

  double get totalCostUsd =>
      trials.fold(0.0, (s, t) => s + t.consumedCostUsd);

  Duration get meanWallClock => trialCount == 0
      ? Duration.zero
      : Duration(
          milliseconds: trials.fold(0, (s, t) => s + t.wallClock.inMilliseconds) ~/
              trialCount);

  Map<String, dynamic> toJson() => {
        'variant': variant,
        'trials': [for (final t in trials) t.toJson()],
        'passed': passed,
        'successRate': successRate,
        'meanScore': meanScore,
        'totalTokens': totalTokens,
        'totalCostUsd': totalCostUsd,
        'meanWallClockMs': meanWallClock.inMilliseconds,
      };
}

/// The whole evaluation: every variant, comparable.
final class EvalReport {
  final List<VariantReport> variants;

  const EvalReport({required this.variants});

  Map<String, dynamic> toJson() =>
      {'variants': [for (final v in variants) v.toJson()]};
}
