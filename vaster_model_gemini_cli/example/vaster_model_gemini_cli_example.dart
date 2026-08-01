import 'package:vaster_model/vaster_model.dart';
import 'package:vaster_model_gemini_cli/vaster_model_gemini_cli.dart';

void main() async {
  print('================================================================');
  print('      Vaster Gemini CLI Backend Model Demonstration            ');
  print('================================================================\n');

  final model = GeminiCliVasterModel(
    executablePath: 'gemini',
    extraArgs: ['--skip-trust'],
  );

  print('Model initialized: ${model.modelName}');
  print('Capabilities: streaming=${model.capabilities.supportsStreaming}, reasoning=${model.capabilities.supportsReasoning}\n');

  print('--- 1. Non-Streaming Generation ---');
  final request = ModelRequest(
    systemInstruction: ChatMessage.system('You are a helpful AI assistant for the Vaster LLM Virtual Machine.'),
    messages: [
      ChatMessage.user('Summarize the purpose of an LLM Virtual Machine in 2 concise sentences.'),
    ],
  );

  try {
    final response = await model.generate(request);
    print('Response:\n${response.message.text}\n');
    print('Tokens: prompt=${response.usage.promptTokenCount}, candidates=${response.usage.candidatesTokenCount}');
  } catch (e) {
    print('Error: $e');
  }

  print('\n--- 2. Streaming Generation ---');
  final streamRequest = ModelRequest(
    messages: [
      ChatMessage.user('List 3 key architectural benefits of separating ISA opcodes from execution engines.'),
    ],
  );

  try {
    final stream = model.generateStream(streamRequest);
    await for (final chunk in stream) {
      if (chunk.textDelta != null) {
        print(chunk.textDelta);
      }
    }
    print('\nStreaming completed successfully.');
  } catch (e) {
    print('Error streaming: $e');
  }
}
