import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';
import 'package:vaster_model/vaster_model.dart';
import 'package:vaster_model_google_ai/vaster_model_google_ai.dart';

void main() {
  group('GoogleAiVasterModel — Configuration & Validation', () {
    test('throws StateError when API key is empty', () {
      final model = GoogleAiVasterModel(apiKey: '');
      expect(
        () => model.generate(const ModelRequest(messages: [])),
        throwsA(isA<StateError>()),
      );
    });

    test('accepts custom target model and base URL', () {
      final model = GoogleAiVasterModel(
        apiKey: 'test-key',
        targetModel: 'gemini-1.5-pro',
      );
      expect(model.targetModel, equals('gemini-1.5-pro'));
      expect(model.apiKey, equals('test-key'));
    });
  });

  group('GoogleAiVasterModel — REST API generate()', () {
    test('sends payload to Google AI API and parses ModelResponse', () async {
      late Uri capturedUrl;
      late Map<String, dynamic> capturedBody;

      final mockClient = MockClient((request) async {
        capturedUrl = request.url;
        capturedBody = jsonDecode(request.body) as Map<String, dynamic>;

        final responseJson = {
          'candidates': [
            {
              'content': {
                'role': 'model',
                'parts': [
                  {'text': 'Hello from Google AI Gemini!'}
                ]
              },
              'finishReason': 'STOP'
            }
          ],
          'usageMetadata': {
            'promptTokenCount': 10,
            'candidatesTokenCount': 6,
            'totalTokenCount': 16
          }
        };

        return http.Response(jsonEncode(responseJson), 200, headers: {
          'content-type': 'application/json',
        });
      });

      final model = GoogleAiVasterModel(
        apiKey: 'fake-api-key',
        httpClient: mockClient,
      );

      final request = ModelRequest(
        systemInstruction: ChatMessage.system('You are a coding assistant.'),
        messages: [
          ChatMessage.user('Hi Gemini!'),
        ],
      );

      final response = await model.generate(request);

      expect(capturedUrl.toString(), contains('models/gemini-2.5-flash:generateContent?key=fake-api-key'));
      expect(capturedBody['contents'].first['role'], equals('user'));
      expect(capturedBody['systemInstruction']['parts'].first['text'], equals('You are a coding assistant.'));

      expect(response.message.text, equals('Hello from Google AI Gemini!'));
      expect(response.finishReason, equals(FinishReason.stop));
      expect(response.usage.promptTokenCount, equals(10));
      expect(response.usage.candidatesTokenCount, equals(6));
    });

    test('throws StateError on non-200 HTTP status code', () async {
      final mockClient = MockClient((request) async {
        return http.Response('{"error": "API Key Invalid"}', 400);
      });

      final model = GoogleAiVasterModel(
        apiKey: 'invalid-key',
        httpClient: mockClient,
      );

      expect(
        () => model.generate(ModelRequest(messages: [ChatMessage.user('Hi')])),
        throwsA(isA<StateError>()),
      );
    });
  });

  group('GoogleAiVasterModel — REST API generateStream()', () {
    test('parses SSE stream deltas from streamGenerateContent', () async {
      final mockClient = MockClient.streaming((request, bodyStream) async {
        final ssePayload = [
          'data: {"candidates":[{"content":{"parts":[{"text":"Hello "}]}}]}\n\n',
          'data: {"candidates":[{"content":{"parts":[{"text":"World!"}]},"finishReason":"STOP"}],"usageMetadata":{"promptTokenCount":5,"candidatesTokenCount":2}}\n\n',
          'data: [DONE]\n\n',
        ].join();

        final stream = Stream.value(utf8.encode(ssePayload));
        return http.StreamedResponse(stream, 200, headers: {
          'content-type': 'text/event-stream',
        });
      });

      final model = GoogleAiVasterModel(
        apiKey: 'fake-api-key',
        httpClient: mockClient,
      );

      final request = ModelRequest(messages: [ChatMessage.user('Stream test')]);
      final chunks = await model.generateStream(request).toList();

      expect(chunks, hasLength(2));
      expect(chunks.first.textDelta, equals('Hello '));
      expect(chunks.last.textDelta, equals('World!'));
      expect(chunks.last.finishReason, equals(FinishReason.stop));
      expect(chunks.last.usage?.promptTokenCount, equals(5));
    });
  });
}
