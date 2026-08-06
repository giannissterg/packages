// ignore_for_file: avoid_print
import 'dart:io';

import 'package:vaster_model/vaster_model.dart';
import 'package:vaster_model_claude_cli/vaster_model_claude_cli.dart';
import 'package:vaster_model_rpc/vaster_model_rpc.dart';
import 'package:vaster_model_rpc_server/vaster_model_rpc_server.dart';

/// End-to-end demo: serve **Claude** through the Vaster RPC sidecar, then call
/// it from a decoupled [RpcVasterModel] client over a Unix Domain Socket.
///
///   dart run example/claude_self_rpc_demo.dart
///
/// Requires the `claude` CLI installed and authenticated. Override the binary
/// path with the CLAUDE_BIN environment variable if it is not on PATH.
Future<void> main() async {
  final claudeBin = Platform.environment['CLAUDE_BIN'] ?? 'claude';
  final socketPath = '${Directory.systemTemp.path}/vaster_claude_demo.sock';

  // 1. The Claude CLI, wrapped as a VasterModel, hosted in the sidecar server.
  final server = VasterModelSidecarServer(
    underlyingModel: ClaudeCliVasterModel(executablePath: claudeBin),
    socketPath: socketPath,
  );
  await server.start();
  print('✓ Claude sidecar listening on $socketPath');

  // 2. A client that only knows about the socket — not that Claude is behind it.
  final client = RpcVasterModel(socketPath: socketPath, modelName: 'claude-via-rpc');

  try {
    final response = await client.generate(
      ModelRequest(
        systemInstruction: ChatMessage.system('You are terse. Answer in one line.'),
        messages: [ChatMessage.user('In one sentence, what is a virtual machine?')],
      ),
    );
    print('\n─ Response from Claude over RPC ─────────────────────────────');
    print(response.text);
    print('─────────────────────────────────────────────────────────────');
    print('tokens: in=${response.usage.promptTokenCount} '
        'out=${response.usage.candidatesTokenCount}');
  } on StateError catch (e) {
    // e.g. "Claude CLI error: Not logged in" — the request still made a full
    // round-trip through the socket, proving the RPC wiring works.
    print('\n! Claude backend returned an error (RPC path still verified):\n  $e');
  } finally {
    await server.stop();
    print('\n✓ Sidecar stopped.');
  }
}
