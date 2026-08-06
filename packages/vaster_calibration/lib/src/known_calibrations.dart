import 'estimate_calibration.dart';

/// The committed profiles — every number here was measured, and every
/// number's confidence is visible in its `sampleCount` and `provenance`.
/// The test suite RE-DERIVES the fitted ones from the committed fixtures
/// and asserts agreement plus error bounds, so these constants cannot
/// silently rot.
abstract final class KnownCalibrations {
  /// Fitted from the committed SDD fidelity tape (paid Gemini run):
  /// median response-side ratio, one sample excluded as implausible for
  /// plain text (its token count covered non-text parts). On the fixture
  /// this profile's mean absolute error is ~14% where the flat `len/4`
  /// heuristic's is ~41% — better, and honestly still an estimate.
  static const EstimateCalibration geminiFlash = EstimateCalibration(
    backendId: 'gemini-2.0-flash',
    charsPerToken: 2.596638655462185,
    sampleCount: 3,
    provenance: 'sdd_fidelity.replay.json (paid run, 2026-08) '
        '(median ratio, 1 implausible excluded)',
  );

  /// The prove-it run's measured CLI-agentic overhead: the static cost
  /// bound assumed API-shaped calls (\$0.0518); the wire-metered reality
  /// was \$0.1157 — a 2.23x factor from the backend exploring the repo
  /// inside its own harness. **n=1**: a single measured data point,
  /// committed because it is the only real number we have and visibly
  /// weak — treat as a floor for suspicion, not a constant of nature.
  static const EstimateCalibration claudeCliAgentic = EstimateCalibration(
    backendId: 'claude-cli',
    charsPerToken: 4.0, // no text fit yet — heuristic ratio retained
    callOverheadFactor: 2.23,
    sampleCount: 1,
    provenance: 'docs/PROVE_IT.md release_scribe run 2026-08-06 '
        '(0.1157 / 0.0518 wire vs bound; n=1)',
  );

  static const List<EstimateCalibration> all = [geminiFlash, claudeCliAgentic];

  /// Profile for a backend/model id, or null — callers compose the
  /// canonical heuristic when no fitted knowledge exists (never a silent
  /// wrong profile).
  static EstimateCalibration? forBackend(String backendId) {
    for (final calibration in all) {
      if (calibration.backendId == backendId) return calibration;
    }
    return null;
  }
}
