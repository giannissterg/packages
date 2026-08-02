import 'package:vaster_model/vaster_model.dart';
import 'package:vaster_model_fake/vaster_model_fake.dart';

void main() async {
  print('=== Vaster Model Interface Example ===');

  // Initialize a model backend (using FakeVasterModel from package:vaster_model_fake)
  final VasterModel model = FakeVasterModel(
    modelName: 'vaster-fake-model-v1',
    defaultResponseText: 'Execution environment ready.',
  );

  print('Model Name: ${model.modelName}');
  print('Model Capabilities: ${model.capabilities}');

  // Create a model request with system instruction, tools, and user message
  final request = ModelRequest(
    systemInstruction: ChatMessage.system(
      'You are an intelligent agent operating inside the Vaster LLM runtime VM.',
    ),
    messages: [
      ChatMessage.user('List files in the project workspace.'),
    ],
    tools: [
      const ToolDefinition(
        name: 'list_files',
        description: 'Lists all files in the current workspace directory.',
        parametersSchema: {
          'type': 'object',
          'properties': {
            'path': {'type': 'string', 'description': 'Directory path to list'},
          },
        },
      ),
    ],
    generationConfig: const GenerationConfig(
      temperature: 0.2,
      maxOutputTokens: 2048,
    ),
  );

  print('\nSending synchronous generation request...');
  final response = await model.generate(request);
  print('Response Finish Reason: ${response.finishReason}');
  print('Response Text: ${response.text}');
  print('Usage Metadata: ${response.usage}');

  print('\nStreaming generation response...');
  final stream = model.generateStream(request);
  await for (final chunk in stream) {
    if (chunk.textDelta != null) {
      final text = chunk.textDelta!;
      print('Chunk: $text');
    }
  }

  print('\nDone!');
}
