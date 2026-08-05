/// Multi-run evaluation for Vaster pipelines.
///
/// Determinism (replay) answered "did it do the same thing?"; the harness
/// answers the question that actually matters: **does it work, how often,
/// and at what cost?** Run a program N times per variant, score every trial
/// with composable scorers, and get success rates with real metered
/// cost/latency per variant.
library;

export 'src/eval_harness.dart';
export 'src/eval_report.dart';
export 'src/scorer.dart';
