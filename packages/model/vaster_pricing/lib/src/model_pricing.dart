import 'package:vaster_model/vaster_model.dart';

/// Per-token rates for one model, in USD per million tokens.
class ModelPricing {
  /// Uncached input rate.
  final double inputUsdPerMTok;

  /// Output rate (thought tokens bill at this rate too).
  final double outputUsdPerMTok;

  /// Cache-read rate (typically ~0.1× input).
  final double cacheReadUsdPerMTok;

  /// Cache-write rate (typically ~1.25× input).
  final double cacheWriteUsdPerMTok;

  const ModelPricing({
    required this.inputUsdPerMTok,
    required this.outputUsdPerMTok,
    double? cacheReadUsdPerMTok,
    double? cacheWriteUsdPerMTok,
  }) : cacheReadUsdPerMTok = cacheReadUsdPerMTok ?? inputUsdPerMTok * 0.1,
       cacheWriteUsdPerMTok = cacheWriteUsdPerMTok ?? inputUsdPerMTok * 1.25;

  /// Zero-cost pricing for local/self-hosted inference.
  static const ModelPricing free = ModelPricing(
    inputUsdPerMTok: 0,
    outputUsdPerMTok: 0,
    cacheReadUsdPerMTok: 0,
    cacheWriteUsdPerMTok: 0,
  );

  /// Computes the cost of [usage] under these rates, using the cache
  /// breakdown ([UsageMetadata.cacheReadTokenCount] /
  /// [UsageMetadata.cacheCreationTokenCount] are subsets of the prompt count;
  /// the remainder bills at the uncached input rate). Thought tokens bill as
  /// output.
  double costOf(UsageMetadata usage) {
    final uncachedInput = usage.promptTokenCount - usage.cacheReadTokenCount - usage.cacheCreationTokenCount;
    final input = uncachedInput < 0 ? 0 : uncachedInput;
    return (input * inputUsdPerMTok +
            usage.cacheReadTokenCount * cacheReadUsdPerMTok +
            usage.cacheCreationTokenCount * cacheWriteUsdPerMTok +
            (usage.candidatesTokenCount + usage.thoughtsTokenCount) * outputUsdPerMTok) /
        1e6;
  }
}
