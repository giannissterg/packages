/// Estimate calibration — composed, never patched in.
///
/// The canonical `len/4` heuristic (`vaster_token_estimate`) stays
/// intact as the ecosystem-wide fallback. This package adds knowledge
/// BESIDE it through the `TokenEstimator` seam: [EstimateCalibration]
/// carries fitted per-backend numbers as data (with provenance and
/// sample counts — confidence is visible, never implied),
/// [CalibratedTokenEstimator] is the seam implementation parameterized
/// by a profile, [TapeCalibrationFitter] learns profiles from recorded
/// replay tapes, and [KnownCalibrations] holds the committed profiles
/// the test suite re-derives and bounds.
library;

export 'src/calibrated_token_estimator.dart';
export 'src/estimate_calibration.dart';
export 'src/known_calibrations.dart';
export 'src/tape_calibration_fitter.dart';
