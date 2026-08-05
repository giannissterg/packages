import 'dart:async';
import 'dart:io';

import 'package:args/args.dart';
import 'package:vaster_llama_ffi/vaster_llama_ffi.dart';
import 'package:vaster_mmap/vaster_mmap.dart';
import 'package:vaster_model/vaster_model.dart';
import 'package:vaster_model_claude_api/vaster_model_claude_api.dart';
import 'package:vaster_model_claude_cli/vaster_model_claude_cli.dart';
import 'package:vaster_model_google_ai/vaster_model_google_ai.dart';
import 'package:vaster_model_rpc_server/vaster_model_rpc_server.dart';

import '../vaster_command.dart';
import 'backend_resolver.dart';

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
      'backend',
      abbr: 'b',
      defaultsTo: 'gemini',
      allowed: const ['gemini', 'claude', 'claude-api', 'llama'],
      help: 'Model backend to expose over the sidecar. '
          '"claude-api" talks to the Claude Messages API directly (typed tools, '
          'caching, exact usage); "claude" shells out to the local claude CLI; '
          '"llama" hosts the in-process FFI engine over shared-memory rings '
          '(zero-copy transport) instead of the socket.',
    );
    parser.addOption(
      'ring',
      defaultsTo: 'vaster_llama',
      help: 'Ring name prefix for --backend llama (creates <ring>_req and '
          '<ring>_res shared-memory rings).',
    );
    parser.addOption(
      'model',
      abbr: 'm',
      help: 'Backend model name (e.g. gemini-2.0-flash, or sonnet/opus for claude). '
          'Defaults per backend.',
    );
    parser.addOption(
      'claude-bin',
      help: 'Path to the Claude CLI binary (claude backend only).',
      defaultsTo: 'claude',
    );
  }

  @override
  Future<int> execute(CommandContext context) async {
    final results = context.parsedResults;
    final out = context.stdoutSink;

    final customSocket = results['socket'] as String?;
    final socketPath = customSocket ?? context.socketPath;
    final backend = results['backend'] as String? ?? 'gemini';
    final modelName = results['model'] as String? ??
        switch (backend) {
          'claude' => 'default',
          'claude-api' => 'claude-opus-5',
          _ => 'gemini-2.0-flash',
        };

    if (backend == 'llama') {
      return _serveLlamaOverRings(context);
    }

    final VasterModel model;
    if (backend == 'claude-api') {
      model = ClaudeApiVasterModel(targetModel: modelName);
    } else if (backend == 'claude') {
      model = ClaudeCliVasterModel(
        executablePath: results['claude-bin'] as String? ?? 'claude',
        selectedModel: results['model'] as String?,
      );
    } else {
      final apiKey =
          Platform.environment['GEMINI_API_KEY'] ?? Platform.environment['GOOGLE_AI_API_KEY'];
      model = GoogleAiVasterModel(apiKey: apiKey, targetModel: modelName);
    }

    out.writeln('======================================================================');
    out.writeln('  VASTER MODEL SIDECAR RPC SERVER                                      ');
    out.writeln('  Target Socket : $socketPath                                          ');
    out.writeln('  Backend       : $backend                                            ');
    out.writeln('  Target Model  : $modelName                                           ');
    out.writeln('======================================================================\n');

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

  /// `--backend llama`: the zero-copy topology — this process owns the
  /// FFI engine and serves envelopes over shared-memory rings; clients
  /// connect with `MmapVasterModel` against the same ring names. Bulk
  /// context rides as named KV frames, never through the rings.
  Future<int> _serveLlamaOverRings(CommandContext context) async {
    final results = context.parsedResults;
    final out = context.stdoutSink;

    final modelPath = results['model'] as String? ??
        Platform.environment['VASTER_LLAMA_MODEL'] ??
        defaultLlamaModelPath();
    if (!File(modelPath).existsSync()) {
      context.stderrSink.writeln(
          'Error: model file not found at "$modelPath" (pass --model '
          '<path.gguf> or set VASTER_LLAMA_MODEL).');
      return 1;
    }
    final ringPrefix = results['ring'] as String? ?? 'vaster_llama';

    final worker = await LlamaWorker.spawn(modelPath: modelPath);
    final kv = LlamaFfiKvCacheController(worker: worker);
    final requestRing = SharedMemoryRing(shmName: '${ringPrefix}_req');
    final responseRing = SharedMemoryRing(shmName: '${ringPrefix}_res');
    final host = LlamaSidecarHost(
      model: LlamaFfiVasterModel(worker: worker, kvController: kv),
      requestRing: requestRing,
      responseRing: responseRing,
    );

    out.writeln('======================================================================');
    out.writeln('  VASTER LLAMA SIDECAR — ZERO-COPY SHARED-MEMORY TRANSPORT');
    out.writeln('  Rings   : ${ringPrefix}_req / ${ringPrefix}_res');
    out.writeln('  Model   : $modelPath');
    out.writeln('======================================================================\n');
    out.writeln('✓ Sidecar is ONLINE — clients: MmapVasterModel on the same rings.');
    out.writeln('Press Ctrl+C to stop.\n');

    final serving = host.serve();
    late StreamSubscription sub;
    sub = ProcessSignal.sigint.watch().listen((_) async {
      out.writeln('\nStopping llama sidecar...');
      host.stop();
      await serving;
      await worker.close();
      requestRing.close();
      responseRing.close();
      await sub.cancel();
      out.writeln('✓ Sidecar stopped.');
    });
    await serving;
    return 0;
  }
}
