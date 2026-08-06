import 'package:vaster_model/vaster_model.dart';

/// Prompt composition for the llama backend, as its own testable class —
/// this is **the alignment contract's owner**: KV prewarm materializes
/// exactly what [renderMessages] renders, and token-exact prefix
/// validation checks prompts composed by [composePrompt] against it, so
/// the two MUST be one piece of logic. Held by the model and injected
/// into the prewarmer; never reached for statically.
final class LlamaPromptComposer {
  const LlamaPromptComposer();

  /// Renders a message run exactly as it appears inside [composePrompt].
  /// State materialized from `renderMessages(region.messages)` is a
  /// byte-identical prefix of a prompt whose leading messages are that
  /// region's — the KV-reuse alignment contract.
  String renderMessages(Iterable<ChatMessage> messages) {
    final buffer = StringBuffer();
    for (final message in messages) {
      final text = message.text.trim();
      if (text.isEmpty) continue;
      buffer.writeln('${message.role.name}: $text');
    }
    return buffer.toString();
  }

  /// Flattens the typed conversation into a plain prompt. Stable content
  /// (system instruction, earlier turns) renders first so materialized
  /// prefixes stay byte-identical across calls — required for KV reuse.
  String composePrompt(ModelRequest request) {
    final buffer = StringBuffer();
    final system = request.systemInstruction?.text.trim();
    if (system != null && system.isNotEmpty) {
      buffer.writeln(system);
      buffer.writeln();
    }
    buffer.write(renderMessages(request.messages));
    buffer.write('model:');
    return buffer.toString();
  }
}
