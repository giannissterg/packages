import 'package:vaster_model/vaster_model.dart';

/// Length-based token estimation (~4 characters per token).
///
/// This is the ONLY sanctioned home for the `/4` heuristic: every estimate in
/// the ecosystem routes through here so estimated numbers are consistent and
/// recognizable. Anything derived from these values must be treated as
/// [UsageSource.estimated] — real charging prefers backend-measured
/// [UsageMetadata] and falls back to this only when the wire reports nothing.
abstract final class TokenEstimate {
  /// Approximate characters per token for English-ish text.
  static const int charsPerToken = 4;

  /// Fixed per-message overhead (role markers, separators), matching the
  /// long-standing session-history estimator.
  static const int perMessageOverhead = 4;

  /// Estimated token count for a raw text span.
  static int forText(String text) => (text.length / charsPerToken).ceil();

  /// Estimated token count for a message transcript, including per-message
  /// structural overhead.
  static int forMessages(Iterable<ChatMessage> messages) => messages.fold(
      0, (sum, m) => sum + forText(m.text) + perMessageOverhead);

  /// Estimated usage for one prompt/output exchange, explicitly labeled
  /// [UsageSource.estimated].
  static UsageMetadata forExchange(
          {required String prompt, required String output}) =>
      UsageMetadata(
        promptTokenCount: forText(prompt),
        candidatesTokenCount: forText(output),
        source: UsageSource.estimated,
      );
}

/// The instance seam for token estimation — the composition point where
/// consumers that CAN know better plug that knowledge in:
/// per-backend calibrated ratios (`vaster_calibration`), or an exact
/// local tokenizer (the llama backend). The static [TokenEstimate]
/// heuristic stays the canonical default and its call sites stay
/// untouched; this interface adds a seam beside it, never a replacement.
///
/// Rule 6.12 binds every implementation exactly as it binds the statics:
/// estimation knows nothing of quotas, budgets, or costs, and anything
/// derived from these values is [UsageSource.estimated] unless the
/// implementation is exact by construction.
abstract interface class TokenEstimator {
  /// Estimated token count for a raw text span.
  int forText(String text);

  /// Estimated token count for a message transcript, including structural
  /// per-message overhead.
  int forMessages(Iterable<ChatMessage> messages);

  /// Estimated usage for one prompt/output exchange.
  UsageMetadata forExchange({required String prompt, required String output});
}

/// The canonical default [TokenEstimator]: delegates every call to the
/// [TokenEstimate] statics, so composing code and legacy call sites
/// compute identical numbers by construction.
final class HeuristicTokenEstimator implements TokenEstimator {
  const HeuristicTokenEstimator();

  @override
  int forText(String text) => TokenEstimate.forText(text);

  @override
  int forMessages(Iterable<ChatMessage> messages) =>
      TokenEstimate.forMessages(messages);

  @override
  UsageMetadata forExchange({required String prompt, required String output}) =>
      TokenEstimate.forExchange(prompt: prompt, output: output);
}
