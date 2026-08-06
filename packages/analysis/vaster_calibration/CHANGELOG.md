# Changelog

## Unreleased

- **BREAKING**: `KnownCalibrations` (static registry) → `CalibrationCatalog`, an instance value with `CalibrationCatalog.builtin` as the committed const catalog (the `PricingCatalog.builtin` idiom) — catalogs compose and merge; no hidden global registry.

- Initial package (roadmap item 4): estimate calibration as **composed
  behavior**. `EstimateCalibration` carries fitted per-backend numbers
  as data with visible provenance and sample counts;
  `CalibratedTokenEstimator` implements the `TokenEstimator` seam beside
  the untouched canonical heuristic; `TapeCalibrationFitter` learns
  profiles from recorded replay tapes — median response-side ratio
  (least squares with intercept overfit the few heterogeneous fixture
  samples to garbage), physically-implausible samples excluded LOUDLY,
  estimated-source usage refused. `KnownCalibrations` commits the
  gemini-flash profile (re-derived from the fixture by test: mean error
  ~14% vs the heuristic's ~41%) and the prove-it claude-cli agentic
  overhead factor (2.23x, openly n=1).
