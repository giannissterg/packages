import 'package:vaster_playground/vaster_playground.dart';

void main(List<String> args) async {
  bool useGeminiCli = args.contains('--gemini') || args.contains('-g');
  String? modelName;

  for (var i = 0; i < args.length; i++) {
    if ((args[i] == '--model' || args[i] == '-m') && i + 1 < args.length) {
      modelName = args[i + 1];
      useGeminiCli = true;
    } else if (args[i].startsWith('--model=')) {
      modelName = args[i].substring('--model='.length);
      useGeminiCli = true;
    }
  }

  await runPlayground(
    useGeminiCli: useGeminiCli,
    modelName: modelName,
  );
}
