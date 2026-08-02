import 'dart:io';

import 'package:test/test.dart';
import 'package:vaster_model/vaster_model.dart';
import 'package:vaster_model_rpc/vaster_model_rpc.dart';
import 'package:vaster_model_rpc_server/vaster_model_rpc_server.dart';

class EchoTestModel implements VasterModel {
  @override
  String get modelName => 'echo-test-model';

  @override
  ModelCapabilities get capabilities => const ModelCapabilities();

  @override
  Future<ModelResponse> generate(ModelRequest request) async {
    final prompt = request.messages.lastOrNull?.text ?? '';
    return ModelResponse(
      message: ChatMessage.model('ECHO_RESPONSE: $prompt'),
      finishReason: FinishReason.stop,
    );
  }

  @override
  Stream<ModelResponseChunk> generateStream(ModelRequest request) async* {
    yield const ModelResponseChunk(textDelta: 'STREAM_1: ');
    yield const ModelResponseChunk(textDelta: 'STREAM_2', finishReason: FinishReason.stop);
  }
}

void main() {
  late Directory tempDir;
  late String socketPath;
  late VasterModelSidecarServer server;
  late RpcVasterModel client;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('vaster_rpc_test_');
    socketPath = '${tempDir.path}/vaster_model.sock';

    server = VasterModelSidecarServer(
      underlyingModel: EchoTestModel(),
      socketPath: socketPath,
    );
    await server.start();

    client = RpcVasterModel(socketPath: socketPath);
  });

  tearDown(() async {
    await server.stop();
    if (tempDir.existsSync()) {
      await tempDir.delete(recursive: true);
    }
  });

  test('RpcVasterModel generates response over Unix Domain Socket RPC', () async {
    final request = ModelRequest(
      messages: [ChatMessage.user('Hello Sidecar!')],
    );

    final response = await client.generate(request);

    expect(response.text, equals('ECHO_RESPONSE: Hello Sidecar!'));
    expect(response.finishReason, equals(FinishReason.stop));
  });

  test('RpcVasterModel streams response chunks over Unix Domain Socket RPC', () async {
    final request = ModelRequest(
      messages: [ChatMessage.user('Stream Me')],
    );

    final chunks = await client.generateStream(request).toList();

    expect(chunks.length, equals(2));
    expect(chunks[0].textDelta, equals('STREAM_1: '));
    expect(chunks[1].textDelta, equals('STREAM_2'));
    expect(chunks[1].finishReason, equals(FinishReason.stop));
  });
}
