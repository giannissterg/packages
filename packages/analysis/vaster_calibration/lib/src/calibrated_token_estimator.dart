import 'package:vaster_model/vaster_model.dart';
import 'package:vaster_token_estimate/vaster_token_estimate.dart';

import 'estimate_calibration.dart';

/// A [TokenEstimator] parameterized by a fitted [EstimateCalibration] —
/// another implementation of the seam, composed beside the canonical
/// heuristic rather than replacing it. Estimates remain
/// [UsageSource.estimated]: calibration narrows the error, it does not
/// make numbers measured.
///
/// Per-message structural overhead intentionally reuses
/// [TokenEstimate.perMessageOverhead] — the tape records no request-side
/// structure to fit it from (v1 fits the text ratio from the response
/// side), so the shared constant stays the one owner of that number.
final class CalibratedTokenEstimator implements TokenEstimator {
  final EstimateCalibration calibration;

  const CalibratedTokenEstimator(this.calibration);

  /// A span is treated as one generation unit: ratio plus the fitted
  /// per-call intercept — the exact form the fit's error bounds hold for.
  @override
  int forText(String text) =>
      (text.length / calibration.charsPerToken + calibration.perCallOverheadTokens).ceil();

  @override
  int forMessages(Iterable<ChatMessage> messages) => messages.fold(
    0,
    (sum, m) => sum + (m.text.length / calibration.charsPerToken).ceil() + TokenEstimate.perMessageOverhead,
  );

  @override
  UsageMetadata forExchange({required String prompt, required String output}) => UsageMetadata(
    promptTokenCount: forText(prompt),
    candidatesTokenCount: forText(output),
    source: UsageSource.estimated,
  );
}
