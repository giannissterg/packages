import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:vaster_model/vaster_model.dart';
import 'unix_socket_protocol.dart';

/// An implementation of [VasterModel] that invokes an out-of-process LLM model
/// sidecar server over Unix Domain Sockets or TCP sockets using zero-dependency RPC.
class RpcVasterModel implements VasterModel {
  /// Path to the Unix Domain Socket file (e.g. `/tmp/vaster_model.sock`).
  final String socketPath;

  /// Optional TCP host if using network sockets instead of Unix sockets.
  final String? tcpHost;

  /// Optional TCP port if using network sockets instead of Unix sockets.
  final int? tcpPort;

  @override
  final String modelName;

  @override
  final ModelCapabilities capabilities;

  RpcVasterModel({
    this.socketPath = '/tmp/vaster_model.sock',
    this.tcpHost,
    this.tcpPort,
    this.modelName = 'rpc-sidecar-model',
    this.capabilities = const ModelCapabilities(
      maxContextTokens: 128000,
      maxOutputTokens: 8192,
      supportsStreaming: true,
      supportsFunctionCalling: true,
      supportsVision: true,
      supportsSystemInstruction: true,
      supportsReasoning: true,
    ),
  });

  @override
  Future<ModelResponse> generate(ModelRequest request) async {
    final socket = await _connect();

    try {
      final reqMap = UnixSocketProtocol.requestToJson('generate', request);
      socket.write('${jsonEncode(reqMap)}\n');
      await socket.flush();

      final responseLine = await socket
          .cast<List<int>>()
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .first;

      final json = jsonDecode(responseLine) as Map<String, dynamic>;
      if (json['status'] == 'error') {
        throw StateError('RPC Sidecar Model Error: ${json['message']}');
      }

      return UnixSocketProtocol.responseFromJson(json);
    } finally {
      await socket.close();
    }
  }

  @override
  Stream<ModelResponseChunk> generateStream(ModelRequest request) async* {
    final socket = await _connect();

    try {
      final reqMap = UnixSocketProtocol.requestToJson('generateStream', request);
      socket.write('${jsonEncode(reqMap)}\n');
      await socket.flush();

      final lines = socket
          .cast<List<int>>()
          .transform(utf8.decoder)
          .transform(const LineSplitter());

      await for (final line in lines) {
        final trimmed = line.trim();
        if (trimmed.isEmpty) continue;

        final json = jsonDecode(trimmed) as Map<String, dynamic>;
        if (json['status'] == 'error') {
          throw StateError('RPC Sidecar Model Stream Error: ${json['message']}');
        }

        if (json['type'] == 'done') break;

        final textDelta = json['textDelta'] as String?;
        final finishStr = json['finishReason'] as String?;
        final finishReason = finishStr != null
            ? FinishReason.values.firstWhere(
                (f) => f.name == finishStr,
                orElse: () => FinishReason.stop,
              )
            : null;

        yield ModelResponseChunk(
          delta: textDelta != null ? TextPart(textDelta) : null,
          textDelta: textDelta,
          finishReason: finishReason,
        );
      }
    } finally {
      await socket.close();
    }
  }

  Future<Socket> _connect() async {
    if (tcpHost != null && tcpPort != null) {
      return await Socket.connect(tcpHost!, tcpPort!);
    }
    final address = InternetAddress(socketPath, type: InternetAddressType.unix);
    return await Socket.connect(address, 0);
  }
}
