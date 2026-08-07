import 'package:vaster_model/vaster_model.dart';

import 'model_pricing.dart';

/// Immutable lookup from model identifier to [ModelPricing].
///
/// Keys are matched by **longest prefix**: an entry `claude-opus-5` prices
/// `claude-opus-5`, `claude-opus-5-20260115`, etc. Backends whose
/// `modelName` is not a model id (e.g. the claude CLI's `claude-cli`) simply
/// miss — which is honest, and irrelevant for backends that wire-report
/// cost, since wire-reported cost always wins in [resolveCostUsd].
class PricingCatalog {
  final Map<String, ModelPricing> _entries;

  const PricingCatalog(Map<String, ModelPricing> entries) : _entries = entries;

  /// A catalog with no rates: computed cost is never available.
  static const PricingCatalog empty = PricingCatalog({});

  /// Built-in rate table. Rates as of 2026-08 — dated constants, not a live
  /// price feed: verify before relying on computed cost for billing, and
  /// override with [withOverrides] when rates move. Wire-reported cost
  /// always takes precedence over these.
  static const PricingCatalog builtin = PricingCatalog({
    // Anthropic (rates as of 2026-08)
    'claude-opus-5': ModelPricing(inputUsdPerMTok: 5, outputUsdPerMTok: 25),
    'claude-fable-5': ModelPricing(inputUsdPerMTok: 5, outputUsdPerMTok: 25),
    'claude-sonnet-5': ModelPricing(inputUsdPerMTok: 3, outputUsdPerMTok: 15),
    'claude-opus-4': ModelPricing(inputUsdPerMTok: 5, outputUsdPerMTok: 25),
    'claude-sonnet-4': ModelPricing(inputUsdPerMTok: 3, outputUsdPerMTok: 15),
    'claude-haiku-4': ModelPricing(inputUsdPerMTok: 1, outputUsdPerMTok: 5),
    // Google (rates as of 2026-08)
    'gemini-2.5-pro': ModelPricing(inputUsdPerMTok: 1.25, outputUsdPerMTok: 10),
    'gemini-2.5-flash': ModelPricing(inputUsdPerMTok: 0.30, outputUsdPerMTok: 2.50),
    'gemini-2.0-flash': ModelPricing(inputUsdPerMTok: 0.10, outputUsdPerMTok: 0.40),
    // Local inference — zero marginal cost.
    'llama-cpp': ModelPricing.free,
    'fake-vaster-model': ModelPricing.free,
  });

  /// Returns the pricing whose key is the longest prefix of [modelId], or
  /// null when nothing matches.
  ModelPricing? lookup(String modelId) {
    ModelPricing? best;
    var bestLength = -1;
    for (final entry in _entries.entries) {
      if (modelId.startsWith(entry.key) && entry.key.length > bestLength) {
        best = entry.value;
        bestLength = entry.key.length;
      }
    }
    return best;
  }

  /// Whether [lookup] would price [modelId].
  bool prices(String modelId) => lookup(modelId) != null;

  /// A new catalog with [overrides] added on top of this one (same keys
  /// replace, new keys extend).
  PricingCatalog withOverrides(Map<String, ModelPricing> overrides) =>
      PricingCatalog({..._entries, ...overrides});

  /// Resolves the cost of [usage] for [modelId]: wire-reported
  /// [UsageMetadata.costUsd] always wins; otherwise the catalog rate computes
  /// it; null when neither exists (cost is then honestly unknown).
  double? resolveCostUsd(UsageMetadata usage, String modelId) =>
      usage.costUsd ?? lookup(modelId)?.costOf(usage);
}
