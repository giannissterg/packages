import 'package:vaster_model/vaster_model.dart';
import 'package:vaster_model_google_ai/vaster_model_google_ai.dart';

void main() async {
  print('================================================================');
  print('      Vaster Google AI Gemini Backend Model Demonstration       ');
  print('================================================================\n');

  // Reads GEMINI_API_KEY from environment or uses default
  final model = GoogleAiVasterModel(targetModel: 'gemini-2.5-flash');

  print('Model initialized: ${model.modelName} (${model.targetModel})');
  print(
    'Capabilities: maxTokens=${model.capabilities.maxContextTokens}, streaming=${model.capabilities.supportsStreaming}\n',
  );

  final apiKeyConfigured = model.apiKey.isNotEmpty;
  if (!apiKeyConfigured) {
    print('Note: GEMINI_API_KEY environment variable is not set.');
    print('Set GEMINI_API_KEY to test live calls against Google AI API.\n');
    return;
  }

  print('--- 1. Non-Streaming Generation ---');
  final request = ModelRequest(
    systemInstruction: ChatMessage.system('You are an expert Dart developer.'),
    messages: [ChatMessage.user('Explain the key benefits of virtual machine architectures in 2 sentences.')],
  );

  try {
    final response = await model.generate(request);
    print('Response:\n${response.message.text}\n');
    print(
      'Tokens: prompt=${response.usage.promptTokenCount}, candidates=${response.usage.candidatesTokenCount}',
    );
  } catch (e) {
    print('Error: $e');
  }

  print('\n--- 2. Streaming Generation ---');
  final streamRequest = ModelRequest(
    messages: [ChatMessage.user('List 3 reasons to decoupling bytecode ISA from execution engines.')],
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
