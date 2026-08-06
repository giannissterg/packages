import 'dart:async';
import 'dart:io';

import 'package:args/args.dart';
import 'package:vaster_mmap/vaster_mmap.dart';
import 'package:vaster_model/vaster_model.dart';
import 'package:vaster_model_claude_api/vaster_model_claude_api.dart';
import 'package:vaster_model_claude_cli/vaster_model_claude_cli.dart';
import 'package:vaster_model_google_ai/vaster_model_google_ai.dart';
import 'package:vaster_model_rpc_server/vaster_model_rpc_server.dart';

import '../vaster_command.dart';
import 'backend_resolver.dart';

/// `vaster serve` — host a model backend for other processes.
///
/// **Backend and transport are orthogonal**: `--backend` picks the model
/// (gemini, claude, claude-api, llama), `--transport` picks how clients
/// reach it — `socket` (newline-JSON over a Unix domain socket, the
/// `rpc` client backend) or `shm` (envelopes over shared-memory rings,
/// the `MmapVasterModel` client; bulk context rides as named KV frames).
/// Any pairing works; KV frame reuse simply requires a backend that owns
/// a KV controller (llama today).
class ServeCommand extends VasterCommand {
  @override
  String get name => 'serve';

  @override
  List<String> get aliases => const ['server'];

  @override
  String get description =>
      'Hosts a model backend for other processes, over a Unix socket or '
      'shared-memory rings.';

  @override
  void configureArgs(ArgParser parser) {
    parser.addOption(
      'transport',
      abbr: 't',
      defaultsTo: 'socket',
      allowed: const ['socket', 'shm'],
      help: 'How clients reach the served model: "socket" = newline-JSON '
          'over a Unix domain socket (client: --backend rpc); "shm" = '
          'envelopes over shared-memory rings with KV state as named '
          'frames (client: MmapVasterModel).',
    );
    parser.addOption(
      'socket',
      abbr: 's',
      help: 'Unix Domain Socket path (--transport socket).',
    );
    parser.addOption(
      'ring',
      defaultsTo: 'vaster_llama',
      help: 'Ring name prefix (--transport shm): creates <ring>_req and '
          '<ring>_res shared-memory rings.',
    );
    parser.addOption(
      'backend',
      abbr: 'b',
      defaultsTo: 'gemini',
      allowed: const ['gemini', 'claude', 'claude-api', 'llama'],
      help: 'Model backend to expose. "claude-api" talks to the Claude '
          'Messages API directly; "claude" shells out to the local claude '
          'CLI; "llama" runs the in-process FFI engine (zero-copy KV '
          'frames when paired with --transport shm).',
    );
    parser.addOption(
      'model',
      abbr: 'm',
      help: 'Backend model name (e.g. gemini-2.0-flash, sonnet/opus for '
          'claude, or a .gguf path for llama). Defaults per backend.',
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
    final backend = results['backend'] as String? ?? 'gemini';
    final transport = results['transport'] as String? ?? 'socket';

    // 1. Backend → model, independent of transport. The llama path goes
    //    through the shared resolver (one owner for its construction and
    //    for disposing the worker it spawns); the rest construct locally
    //    and own nothing that needs disposal.
    final VasterModel model;
    var dispose = _noDispose;
    if (backend == 'llama') {
      try {
        final resolved = await resolveBackendModel(
            results: results, context: context, err: context.stderrSink);
        model = resolved.model;
        dispose = resolved.dispose;
      } on StateError catch (e) {
        context.stderrSink.writeln('Error: ${e.message}');
        return 1;
      }
    } else if (backend == 'claude-api') {
      model = ClaudeApiVasterModel(
          targetModel: results['model'] as String? ?? 'claude-opus-5');
    } else if (backend == 'claude') {
      model = ClaudeCliVasterModel(
        executablePath: results['claude-bin'] as String? ?? 'claude',
        selectedModel: results['model'] as String?,
      );
    } else {
      model = GoogleAiVasterModel(
        apiKey: Platform.environment['GEMINI_API_KEY'] ??
            Platform.environment['GOOGLE_AI_API_KEY'],
        targetModel: results['model'] as String? ?? 'gemini-2.0-flash',
      );
    }

    // 2. Transport, independent of backend.
    try {
      return transport == 'shm'
          ? await _serveOverRings(context, model)
          : await _serveOverSocket(context, model);
    } finally {
      await dispose();
    }
  }

  static Future<void> _noDispose() async {}

  Future<int> _serveOverSocket(
      CommandContext context, VasterModel model) async {
    final out = context.stdoutSink;
    final socketPath =
        context.parsedResults['socket'] as String? ?? context.socketPath;

    out.writeln('======================================================================');
    out.writeln('  VASTER MODEL SIDECAR — UNIX SOCKET TRANSPORT');
    out.writeln('  Socket  : $socketPath');
    out.writeln('  Model   : ${model.modelName}');
    out.writeln('======================================================================\n');

    final server = VasterModelSidecarServer(
      underlyingModel: model,
      socketPath: socketPath,
    );
    await server.start();
    out.writeln('✓ Sidecar is ONLINE — clients: --backend rpc on the same socket.');
    out.writeln('Press Ctrl+C to stop.\n');

    final completer = Completer<int>();
    late StreamSubscription<Object?> sub;
    sub = ProcessSignal.sigint.watch().listen((_) async {
      out.writeln('\nStopping sidecar...');
      await server.stop();
      await sub.cancel();
      out.writeln('✓ Sidecar stopped.');
      completer.complete(0);
    });
    return completer.future;
  }

  /// Rings owned here, host from `vaster_mmap` — backend-agnostic
  /// transport code serving whatever model step 1 built. Unwind
  /// discipline (Rule 5): every acquisition is released on every exit
  /// path, including a serve-loop failure.
  Future<int> _serveOverRings(CommandContext context, VasterModel model) async {
    final out = context.stdoutSink;
    final ringPrefix =
        context.parsedResults['ring'] as String? ?? 'vaster_llama';

    SharedMemoryRing? requestRing;
    SharedMemoryRing? responseRing;
    StreamSubscription<Object?>? sub;
    try {
      requestRing = SharedMemoryRing(shmName: '${ringPrefix}_req');
      responseRing = SharedMemoryRing(shmName: '${ringPrefix}_res');
      final host = RingSidecarHost(
        model: model,
        requestRing: requestRing,
        responseRing: responseRing,
      );

      out.writeln('======================================================================');
      out.writeln('  VASTER MODEL SIDECAR — SHARED-MEMORY RING TRANSPORT');
      out.writeln('  Rings   : ${ringPrefix}_req / ${ringPrefix}_res');
      out.writeln('  Model   : ${model.modelName}');
      out.writeln('======================================================================\n');
      out.writeln('✓ Sidecar is ONLINE — clients: MmapVasterModel on the same rings.');
      out.writeln('Press Ctrl+C to stop.\n');

      final serving = host.serve();
      sub = ProcessSignal.sigint.watch().listen((_) {
        out.writeln('\nStopping sidecar...');
        host.stop();
      });
      await serving;
      out.writeln('✓ Sidecar stopped.');
      return 0;
    } finally {
      await sub?.cancel();
      requestRing?.close();
      responseRing?.close();
    }
  }
}
