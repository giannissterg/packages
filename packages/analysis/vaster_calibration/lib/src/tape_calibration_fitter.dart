import 'package:vaster_model/vaster_model.dart';
import 'package:vaster_replay/vaster_replay.dart';

import 'estimate_calibration.dart';

/// The result of fitting: the profile plus its own honest error report
/// against the samples it was fitted on — and a loud account of what was
/// excluded and why. A fit that hides its residuals is a lie with a
/// decimal point.
final class CalibrationFit {
  final EstimateCalibration calibration;

  /// Mean absolute error of `chars/ratio` vs measured tokens over the
  /// included samples, as a fraction (0.14 = 14%).
  final double meanAbsErrorFraction;

  /// Worst single included sample's absolute error fraction.
  final double maxAbsErrorFraction;

  /// Samples excluded as physically impossible for plain text (token
  /// count covering non-text parts the recorded text lacks). Never
  /// silent: exclusion is data about the tape, not noise to hide.
  final int excludedSamples;

  const CalibrationFit({
    required this.calibration,
    required this.meanAbsErrorFraction,
    required this.maxAbsErrorFraction,
    required this.excludedSamples,
  });

  @override
  String toString() =>
      'CalibrationFit($calibration, '
      'meanErr ${(meanAbsErrorFraction * 100).toStringAsFixed(1)}%, '
      'maxErr ${(maxAbsErrorFraction * 100).toStringAsFixed(1)}%'
      '${excludedSamples > 0 ? ', $excludedSamples excluded' : ''})';
}

/// Fits an [EstimateCalibration] from a recorded [ModelTape] — measured
/// wire usage against recorded text, per backend.
///
/// **Scope and model (v1, stated honestly):**
///  * The tape stores full *response* text with measured
///    `candidatesTokenCount` but only a request *preview*, so the ratio
///    is fitted from the response side. Text is text — the ratio applies
///    to prompt estimation too — but request-side structural overhead is
///    not fittable until the tape records request char counts (a
///    deliberate tape-v2 note).
///  * The estimator is the **median** chars-per-token ratio through the
///    origin. Real tapes are few, heterogeneous samples (prose vs
///    markdown vs code); least squares with an intercept overfits that
///    to garbage — the first fixture fit produced a 388-token intercept
///    and 137% mean error. The median is robust to exactly this.
///  * Samples whose ratio falls below [minPlausibleCharsPerToken] are
///    excluded LOUDLY ([CalibrationFit.excludedSamples]): no tokenizer
///    produces more tokens than characters on plain text, so such a
///    sample's token count covered parts the recorded text does not.
final class TapeCalibrationFitter {
  /// Below this chars-per-token a text sample is physically implausible.
  final double minPlausibleCharsPerToken;

  const TapeCalibrationFitter({this.minPlausibleCharsPerToken = 1.5});

  /// Fits from [tape]. Throws [StateError] when fewer than [minSamples]
  /// plausible samples exist — a fit from nothing is not a fit.
  CalibrationFit fit(
    ModelTape tape, {
    required String backendId,
    required String provenance,
    int minSamples = 3,
  }) {
    final ratios = <double>[];
    final samples = <(int chars, int tokens)>[];
    var excluded = 0;
    for (final entry in tape.entries) {
      final response = ModelResponse.fromJson(entry.responseJson);
      final tokens = response.usage.candidatesTokenCount;
      final chars = response.text.length;
      if (tokens <= 0 || chars <= 0) continue;
      if (response.usage.source != UsageSource.measured) continue;
      final ratio = chars / tokens;
      if (ratio < minPlausibleCharsPerToken) {
        excluded++;
        continue;
      }
      ratios.add(ratio);
      samples.add((chars, tokens));
    }
    if (samples.length < minSamples) {
      throw StateError(
        'only ${samples.length} plausible samples in the '
        'tape (need >= $minSamples; $excluded excluded as implausible) — '
        'refusing to fit a profile from noise.',
      );
    }

    ratios.sort();
    final mid = ratios.length ~/ 2;
    final median = ratios.length.isOdd ? ratios[mid] : (ratios[mid - 1] + ratios[mid]) / 2;

    final calibration = EstimateCalibration(
      backendId: backendId,
      charsPerToken: median,
      sampleCount: samples.length,
      provenance: '$provenance (median ratio, $excluded implausible excluded)',
    );

    var sumErr = 0.0;
    var maxErr = 0.0;
    for (final (chars, tokens) in samples) {
      final predicted = chars / median;
      final err = (predicted - tokens).abs() / tokens;
      sumErr += err;
      if (err > maxErr) maxErr = err;
    }
    return CalibrationFit(
      calibration: calibration,
      meanAbsErrorFraction: sumErr / samples.length,
      maxAbsErrorFraction: maxErr,
      excludedSamples: excluded,
    );
  }
}

/// Prompt-side extension of [TapeCalibrationFitter]: fits the
/// whole-request chars-per-token ratio from v2 tapes (full recorded
/// requests + measured `promptTokenCount`). v1 preview-only entries
/// cannot contribute and are skipped — the exact limitation tape v2
/// exists to remove.
extension PromptSideFitting on TapeCalibrationFitter {
  CalibrationFit fitPromptSide(
    ModelTape tape, {
    required String backendId,
    required String provenance,
    int minSamples = 3,
  }) {
    final ratios = <double>[];
    final samples = <(int chars, int tokens)>[];
    var excluded = 0;
    for (final entry in tape.entries) {
      final recorded = entry.recorded;
      if (recorded is! FullRecordedRequest) continue;
      final request = recorded.toRequest();
      final response = ModelResponse.fromJson(entry.responseJson);
      final tokens = response.usage.promptTokenCount;
      if (tokens <= 0) continue;
      if (response.usage.source != UsageSource.measured) continue;
      final chars =
          (request.systemInstruction?.text.length ?? 0) +
          request.messages.fold<int>(0, (s, m) => s + m.text.length);
      if (chars <= 0) continue;
      final ratio = chars / tokens;
      if (ratio < minPlausibleCharsPerToken) {
        excluded++;
        continue;
      }
      ratios.add(ratio);
      samples.add((chars, tokens));
    }
    if (samples.length < minSamples) {
      throw StateError(
        'only ${samples.length} plausible prompt-side '
        'samples (need >= $minSamples; $excluded excluded; v1 entries '
        'cannot contribute) — refusing to fit.',
      );
    }
    ratios.sort();
    final mid = ratios.length ~/ 2;
    final median = ratios.length.isOdd ? ratios[mid] : (ratios[mid - 1] + ratios[mid]) / 2;
    final calibration = EstimateCalibration(
      backendId: backendId,
      charsPerToken: median,
      sampleCount: samples.length,
      provenance:
          '$provenance (prompt-side median ratio, '
          '$excluded implausible excluded)',
    );
    var sumErr = 0.0;
    var maxErr = 0.0;
    for (final (chars, tokens) in samples) {
      final err = ((chars / median) - tokens).abs() / tokens;
      sumErr += err;
      if (err > maxErr) maxErr = err;
    }
    return CalibrationFit(
      calibration: calibration,
      meanAbsErrorFraction: sumErr / samples.length,
      maxAbsErrorFraction: maxErr,
      excludedSamples: excluded,
    );
  }
}
