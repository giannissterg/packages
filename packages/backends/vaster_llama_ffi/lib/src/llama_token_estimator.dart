import 'package:vaster_model/vaster_model.dart';
import 'package:vaster_token_estimate/vaster_token_estimate.dart';

import 'llama_engine.dart';

/// The `TokenEstimator` seam's strongest implementation: **exact** token
/// counts from the real tokenizer of a loaded [LlamaEngine]. Where the
/// heuristic guesses and a calibration narrows the guess, this one
/// counts — usage it produces is labeled measured because it is true by
/// construction (of token counts; it says nothing about billing).
///
/// Structural per-message overhead reuses the shared
/// [TokenEstimate.perMessageOverhead] constant: message framing is
/// prompt-composition-specific, not a property of the tokenizer, and
/// that number keeps its one owner.
final class LlamaTokenEstimator implements TokenEstimator {
  final LlamaEngine engine;

  const LlamaTokenEstimator(this.engine);

  @override
  int forText(String text) =>
      text.isEmpty ? 0 : engine.tokenize(text, addBos: false).length;

  @override
  int forMessages(Iterable<ChatMessage> messages) => messages.fold(
      0, (sum, m) => sum + forText(m.text) + TokenEstimate.perMessageOverhead);

  @override
  UsageMetadata forExchange({required String prompt, required String output}) =>
      UsageMetadata(
        promptTokenCount: forText(prompt),
        candidatesTokenCount: forText(output),
        source: UsageSource.measured,
      );
}
