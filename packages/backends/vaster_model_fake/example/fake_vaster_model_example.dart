import 'package:vaster_model/vaster_model.dart';
import 'package:vaster_model_fake/vaster_model_fake.dart';

void main() async {
  print('=== Vaster Model Fake Backend Example ===');

  final VasterModel model = FakeVasterModel(
    modelName: 'vaster-fake-model-v1',
    defaultResponseText: 'Fake backend system online.',
  );

  print('Model Name: ${model.modelName}');
  print('Capabilities: ${model.capabilities}');

  final request = ModelRequest(
    systemInstruction: ChatMessage.system('System prompt initialized.'),
    messages: [ChatMessage.user('Execute test task.')],
  );

  final response = await model.generate(request);
  print('Response text: ${response.text}');

  print('\nStreaming deltas...');
  await for (final chunk in model.generateStream(request)) {
    if (chunk.textDelta != null) {
      print('Delta: ${chunk.textDelta}');
    }
  }

  print('\nDone!');
}
