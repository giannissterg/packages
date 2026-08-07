import 'package:test/test.dart';
import 'package:vaster_model/vaster_model.dart';
import 'package:vaster_pricing/vaster_pricing.dart';

void main() {
  group('ModelPricing.costOf', () {
    test('bills uncached input, cache read/write, and output at their rates', () {
      const pricing = ModelPricing(
        inputUsdPerMTok: 10,
        outputUsdPerMTok: 50,
        cacheReadUsdPerMTok: 1,
        cacheWriteUsdPerMTok: 12.5,
      );
      const usage = UsageMetadata(
        promptTokenCount: 1000000, // 700k uncached + 200k read + 100k write
        cacheReadTokenCount: 200000,
        cacheCreationTokenCount: 100000,
        candidatesTokenCount: 100000,
        thoughtsTokenCount: 20000,
      );

      // 700k*10 + 200k*1 + 100k*12.5 + 120k*50 all per MTok
      expect(pricing.costOf(usage), closeTo(7.0 + 0.2 + 1.25 + 6.0, 1e-9));
    });

    test('cache rates default to 0.1x / 1.25x of input', () {
      const pricing = ModelPricing(inputUsdPerMTok: 10, outputUsdPerMTok: 50);
      expect(pricing.cacheReadUsdPerMTok, closeTo(1.0, 1e-9));
      expect(pricing.cacheWriteUsdPerMTok, closeTo(12.5, 1e-9));
    });
  });

  group('PricingCatalog', () {
    test('longest prefix wins', () {
      const catalog = PricingCatalog({
        'claude': ModelPricing(inputUsdPerMTok: 1, outputUsdPerMTok: 1),
        'claude-opus-5': ModelPricing(inputUsdPerMTok: 5, outputUsdPerMTok: 25),
      });
      expect(catalog.lookup('claude-opus-5-20260115')!.inputUsdPerMTok, equals(5));
      expect(catalog.lookup('claude-sonnet-x')!.inputUsdPerMTok, equals(1));
      expect(catalog.lookup('gpt-x'), isNull);
    });

    test('builtin prices known models and local backends at zero', () {
      expect(PricingCatalog.builtin.prices('claude-opus-5'), isTrue);
      expect(PricingCatalog.builtin.prices('gemini-2.0-flash'), isTrue);
      expect(
        PricingCatalog.builtin.lookup('llama-cpp')!.costOf(const UsageMetadata(promptTokenCount: 1000000)),
        equals(0),
      );
      expect(PricingCatalog.builtin.prices('unknown-model'), isFalse);
    });

    test('resolveCostUsd: wire-reported cost wins over computed', () {
      const usage = UsageMetadata(promptTokenCount: 1000000, candidatesTokenCount: 0, costUsd: 42.0);
      const noWire = UsageMetadata(promptTokenCount: 1000000);

      final catalog = PricingCatalog.empty.withOverrides({
        'm': const ModelPricing(inputUsdPerMTok: 10, outputUsdPerMTok: 0),
      });

      expect(catalog.resolveCostUsd(usage, 'm'), equals(42.0));
      expect(catalog.resolveCostUsd(noWire, 'm'), closeTo(10.0, 1e-9));
      expect(catalog.resolveCostUsd(noWire, 'unknown'), isNull);
    });
  });
}
