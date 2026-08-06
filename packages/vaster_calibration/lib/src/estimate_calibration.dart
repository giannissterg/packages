/// A fitted, per-backend estimation profile — **calibration is data**,
/// carried as a value and composed into estimators, never patched into
/// the canonical heuristic (which stays intact as the fallback the whole
/// ecosystem shares).
///
/// Provenance is part of the value: every profile says where its numbers
/// came from and how many samples stand behind them, so a consumer can
/// judge confidence instead of trusting silently.
final class EstimateCalibration {
  /// Backend this profile was fitted against (e.g. `gemini-2.0-flash`).
  final String backendId;

  /// Fitted characters-per-token ratio for generated/plain text.
  final double charsPerToken;

  /// Fitted fixed per-call token intercept (structural overhead the
  /// linear term does not explain).
  final double perCallOverheadTokens;

  /// Multiplier on a whole call's estimated cost for backends whose
  /// harness does work beyond the visible prompt (CLI-agentic backends
  /// explore repos inside their own loop — the prove-it run measured the
  /// static bound low by this factor). `1.0` = no overhead.
  final double callOverheadFactor;

  /// Number of measured samples behind the fit — the confidence signal.
  final int sampleCount;

  /// Where the numbers came from (fixture name, run, date).
  final String provenance;

  const EstimateCalibration({
    required this.backendId,
    required this.charsPerToken,
    this.perCallOverheadTokens = 0,
    this.callOverheadFactor = 1.0,
    required this.sampleCount,
    required this.provenance,
  });

  Map<String, dynamic> toJson() => {
        'backendId': backendId,
        'charsPerToken': charsPerToken,
        'perCallOverheadTokens': perCallOverheadTokens,
        'callOverheadFactor': callOverheadFactor,
        'sampleCount': sampleCount,
        'provenance': provenance,
      };

  factory EstimateCalibration.fromJson(Map<String, dynamic> json) =>
      EstimateCalibration(
        backendId: json['backendId'] as String,
        charsPerToken: (json['charsPerToken'] as num).toDouble(),
        perCallOverheadTokens:
            (json['perCallOverheadTokens'] as num? ?? 0).toDouble(),
        callOverheadFactor:
            (json['callOverheadFactor'] as num? ?? 1.0).toDouble(),
        sampleCount: json['sampleCount'] as int,
        provenance: json['provenance'] as String,
      );

  @override
  String toString() => 'EstimateCalibration($backendId: '
      '${charsPerToken.toStringAsFixed(2)} chars/token '
      '+${perCallOverheadTokens.toStringAsFixed(1)}/call, '
      'x${callOverheadFactor.toStringAsFixed(2)} overhead, '
      'n=$sampleCount, $provenance)';
}
