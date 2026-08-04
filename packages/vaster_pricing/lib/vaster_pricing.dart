/// Monetary pricing for Vaster model usage.
///
/// Concept unawareness: pricing must NOT know about sessions, context,
/// runtimes, or opcode execution. It maps (provider, modelId) to rates and
/// rates × usage to dollars, nothing else. Model backends must NOT know
/// about pricing tables — they only *measure* (wire-reported `costUsd`
/// lives on `UsageMetadata`).
library;

export 'src/model_pricing.dart';
export 'src/pricing_catalog.dart';
