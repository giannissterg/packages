import 'dart:io';

import 'package:test/test.dart';
import 'package:vaster_model/vaster_model.dart';
import 'package:vaster_model_rpc/vaster_model_rpc.dart';
import 'package:vaster_model_rpc_server/vaster_model_rpc_server.dart';

/// Fully-populated usage so the round-trip test proves every field crosses
/// the wire.
const richUsage = UsageMetadata(
  promptTokenCount: 1500,
  candidatesTokenCount: 250,
  thoughtsTokenCount: 40,
  cacheReadTokenCount: 1200,
  cacheCreationTokenCount: 100,
  costUsd: 0.0375,
  source: UsageSource.measured,
);

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
      usage: richUsage,
    );
  }

  @override
  Stream<ModelResponseChunk> generateStream(ModelRequest request) async* {
    yield const ModelResponseChunk(textDelta: 'STREAM_1: ');
    yield const ModelResponseChunk(
      textDelta: 'STREAM_2',
      finishReason: FinishReason.stop,
      usage: richUsage,
    );
  }
}

void expectRichUsage(UsageMetadata usage) {
  expect(usage.promptTokenCount, equals(1500));
  expect(usage.candidatesTokenCount, equals(250));
  expect(usage.thoughtsTokenCount, equals(40));
  expect(usage.cacheReadTokenCount, equals(1200));
  expect(usage.cacheCreationTokenCount, equals(100));
  expect(usage.costUsd, equals(0.0375));
  expect(usage.source, equals(UsageSource.measured));
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

  test('full usage crosses the wire field-for-field (generate)', () async {
    final response = await client.generate(
        ModelRequest(messages: [ChatMessage.user('usage?')]));
    expectRichUsage(response.usage);
  });

  test('full usage crosses the wire on the terminal stream chunk', () async {
    final chunks = await client
        .generateStream(ModelRequest(messages: [ChatMessage.user('usage?')]))
        .toList();

    expect(chunks[0].usage, isNull);
    expect(chunks.last.usage, isNotNull);
    expectRichUsage(chunks.last.usage!);
  });
}
