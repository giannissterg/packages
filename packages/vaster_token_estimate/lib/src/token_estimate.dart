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
