import 'dart:io';

import 'package:vaster_model_google_ai/vaster_model_google_ai.dart';
import 'package:vaster_model_rpc_server/vaster_model_rpc_server.dart';

void main(List<String> args) async {
  final homeDir = Platform.environment['HOME'] ?? '';
  final defaultSocket = '$homeDir/.gemini/antigravity/vaster_model.sock';
  final socketPath = args.isNotEmpty ? args.first : defaultSocket;

  // Ensure target socket directory exists
  final socketFile = File(socketPath);
  final parentDir = socketFile.parent;
  if (!parentDir.existsSync()) {
    parentDir.createSync(recursive: true);
  }

  print('======================================================================');
  print('  ANTIGRAVITY VASTER MODEL SIDECAR SERVER                             ');
  print('  Unix Socket: $socketPath                                            ');
  print('======================================================================\n');

  final apiKey = Platform.environment['GEMINI_API_KEY'] ?? Platform.environment['GOOGLE_AI_API_KEY'];
  final model = GoogleAiVasterModel(
    apiKey: apiKey,
    targetModel: 'gemini-2.0-flash',
  );

  final server = VasterModelSidecarServer(
    underlyingModel: model,
    socketPath: socketPath,
  );

  await server.start();
  print('✓ Antigravity Vaster Model Sidecar is ONLINE and listening for RPC requests!');
  print('Press Ctrl+C to terminate.\n');

  ProcessSignal.sigint.watch().listen((_) async {
    print('\nStopping Antigravity Sidecar Server...');
    await server.stop();
    print('✓ Sidecar Server stopped.');
    exit(0);
  });
}
