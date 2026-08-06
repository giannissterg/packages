/// Unified model-call metering for Vaster.
///
/// Every component that owns a model call meters it through one
/// [ModelCallMeter] instead of hand-rolling the same four steps (resolve
/// cost, publish telemetry, charge tokens, charge cost) at each site.
library;

export 'src/model_call_meter.dart';
export 'src/usage_sink.dart';
