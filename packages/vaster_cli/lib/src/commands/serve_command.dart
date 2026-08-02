import 'dart:async';
import 'dart:io';

import 'package:args/args.dart';
import 'package:vaster_model_google_ai/vaster_model_google_ai.dart';
import 'package:vaster_model_rpc_server/vaster_model_rpc_server.dart';

import '../vaster_command.dart';

class ServeCommand extends VasterCommand {
  @override
  String get name => 'serve';

  @override
  List<String> get aliases => const ['server'];

  @override
  String get description => 'Starts an out-of-process VasterModel Sidecar RPC Server listening on a socket.';

  @override
  void configureArgs(ArgParser parser) {
    parser.addOption(
      'socket',
      abbr: 's',
      help: 'Target Unix Domain Socket file path.',
    );
    parser.addOption(
      'model',
      abbr: 'm',
      defaultsTo: 'gemini-2.0-flash',
      help: 'Target Gemini model name.',
    );
  }

  @override
  Future<int> execute(CommandContext context) async {
    final results = context.parsedResults;
    final out = context.stdoutSink;

    final customSocket = results['socket'] as String?;
    final socketPath = customSocket ?? context.socketPath;
    final modelName = results['model'] as String? ?? 'gemini-2.0-flash';

    out.writeln('======================================================================');
    out.writeln('  VASTER MODEL SIDECAR RPC SERVER                                      ');
    out.writeln('  Target Socket: $socketPath                                           ');
    out.writeln('  Target Model : $modelName                                            ');
    out.writeln('======================================================================\n');

    final apiKey = Platform.environment['GEMINI_API_KEY'] ?? Platform.environment['GOOGLE_AI_API_KEY'];
    final model = GoogleAiVasterModel(
      apiKey: apiKey,
      targetModel: modelName,
    );

    final server = VasterModelSidecarServer(
      underlyingModel: model,
      socketPath: socketPath,
    );

    await server.start();
    out.writeln('✓ Vaster Model Sidecar is ONLINE and listening on Unix Socket!');
    out.writeln('Press Ctrl+C to stop the sidecar server.\n');

    final completer = Completer<int>();
    late StreamSubscription sub;
    sub = ProcessSignal.sigint.watch().listen((_) async {
      out.writeln('\nStopping Vaster Sidecar Server...');
      await server.stop();
      await sub.cancel();
      out.writeln('✓ Server stopped.');
      completer.complete(0);
    });

    return await completer.future;
  }
}
