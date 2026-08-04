import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:vaster_model/vaster_model.dart';
import 'package:vaster_model_rpc/vaster_model_rpc.dart';

/// An out-of-process Unix Domain Socket / TCP sidecar server host exposing a [VasterModel] backend.
class VasterModelSidecarServer {
  final VasterModel underlyingModel;
  final String socketPath;
  final String? tcpHost;
  final int? tcpPort;

  ServerSocket? _serverSocket;
  StreamSubscription<Socket>? _subscription;

  VasterModelSidecarServer({
    required this.underlyingModel,
    this.socketPath = '/tmp/vaster_model.sock',
    this.tcpHost,
    this.tcpPort,
  });

  /// Starts listening for RPC connections on the specified socket.
  Future<void> start() async {
    if (tcpHost != null && tcpPort != null) {
      _serverSocket = await ServerSocket.bind(tcpHost!, tcpPort!);
    } else {
      // Remove existing socket file if left over from a previous crash
      final file = File(socketPath);
      if (file.existsSync()) {
        try {
          file.deleteSync();
        } catch (_) {}
      }
      final address = InternetAddress(socketPath, type: InternetAddressType.unix);
      _serverSocket = await ServerSocket.bind(address, 0);
    }

    _subscription = _serverSocket!.listen(_handleConnection);
  }

  /// Stops the sidecar server and removes the socket file.
  Future<void> stop() async {
    await _subscription?.cancel();
    await _serverSocket?.close();
    if (tcpHost == null) {
      final file = File(socketPath);
      if (file.existsSync()) {
        try {
          file.deleteSync();
        } catch (_) {}
      }
    }
  }

  void _handleConnection(Socket clientSocket) {
    clientSocket
        .cast<List<int>>()
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
      (line) async {
        final trimmed = line.trim();
        if (trimmed.isEmpty) return;

        try {
          final json = jsonDecode(trimmed) as Map<String, dynamic>;
          final command = json['command'] as String? ?? 'generate';

          if (command == 'generate') {
            final request = UnixSocketProtocol.requestFromJson(json);
            final response = await underlyingModel.generate(request);
            final respMap = UnixSocketProtocol.responseToJson(response);
            clientSocket.write('${jsonEncode(respMap)}\n');
            await clientSocket.flush();
          } else if (command == 'generateStream') {
            final request = UnixSocketProtocol.requestFromJson(json);
            await for (final chunk in underlyingModel.generateStream(request)) {
              final chunkMap = {
                'status': 'ok',
                'textDelta': chunk.textDelta,
                'finishReason': chunk.finishReason?.name,
                // Cumulative usage snapshot (take-last semantics); without it
                // every model behind the sidecar streams zero usage and
                // silently defeats budget enforcement.
                if (chunk.usage != null) 'usage': chunk.usage!.toJson(),
              };
              clientSocket.write('${jsonEncode(chunkMap)}\n');
              await clientSocket.flush();
            }
            clientSocket.write('${jsonEncode({'status': 'ok', 'type': 'done'})}\n');
            await clientSocket.flush();
          } else {
            clientSocket.write(
              '${jsonEncode({'status': 'error', 'message': 'Unknown RPC command: $command'})}\n',
            );
            await clientSocket.flush();
          }
        } catch (e, st) {
          try {
            clientSocket.write(
              '${jsonEncode({'status': 'error', 'message': '$e\n$st'})}\n',
            );
            await clientSocket.flush();
          } catch (_) {}
        } finally {
          await clientSocket.close();
        }
      },
      onError: (err) {
        clientSocket.close();
      },
    );
  }
}
