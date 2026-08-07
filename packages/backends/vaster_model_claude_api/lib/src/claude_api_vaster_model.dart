import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:vaster_model/vaster_model.dart';

/// A [VasterModel] backend speaking the **Claude Messages API** directly over
/// HTTP (`POST /v1/messages`) — the compiler-level transport for Vaster.
///
/// Where the CLI backend flattens everything to text, this backend preserves
/// the typed contract end to end:
///
/// | Vaster contract               | Messages API lowering                     |
/// |-------------------------------|-------------------------------------------|
/// | `FunctionCallPart`/`Response` | `tool_use` / `tool_result` content blocks |
/// | `ToolDefinition`              | typed tool with `input_schema`            |
/// | `GenerationConfig.responseSchema` | structured outputs (`output_config.format`) |
/// | `ContextCacheHint`            | `cache_control` prompt-cache breakpoints  |
/// | `UsageMetadata`               | exact server `usage` token counts         |
/// | `FinishReason.safety`         | `stop_reason: "refusal"`                  |
///
/// Authentication: pass [apiKey] explicitly or set `ANTHROPIC_API_KEY`.
/// An OAuth bearer token can be supplied via [authToken] instead.
class ClaudeApiVasterModel implements VasterModel {
  static const _anthropicVersion = '2023-06-01';

  /// API endpoint base (override for proxies/gateways).
  final String baseUrl;

  /// Anthropic API key. Falls back to the `ANTHROPIC_API_KEY` env var.
  final String? apiKey;

  /// OAuth bearer token alternative to [apiKey].
  final String? authToken;

  /// Target model id (default: `claude-opus-5`).
  final String targetModel;

  /// Default `max_tokens` when the request does not specify one.
  final int defaultMaxTokens;

  /// When true, tool definitions are sent with `strict: true` so tool inputs
  /// are guaranteed to validate exactly against their JSON schema. Requires
  /// schemas with `additionalProperties: false` (injected automatically).
  final bool strictTools;

  /// Injectable HTTP client for testing.
  final http.Client Function() _clientFactory;

  @override
  final String modelName;

  @override
  final ModelCapabilities capabilities;

  ClaudeApiVasterModel({
    this.baseUrl = 'https://api.anthropic.com',
    this.apiKey,
    this.authToken,
    this.targetModel = 'claude-opus-5',
    this.defaultMaxTokens = 16000,
    this.strictTools = false,
    http.Client Function()? clientFactory,
    String? modelName,
    this.capabilities = const ModelCapabilities(
      maxContextTokens: 1000000,
      maxOutputTokens: 128000,
      supportsStreaming: true,
      supportsFunctionCalling: true,
      supportsVision: true,
      supportsSystemInstruction: true,
      supportsReasoning: true,
    ),
  }) : _clientFactory = clientFactory ?? http.Client.new,
       modelName = modelName ?? targetModel;

  Map<String, String> _headers({bool stream = false}) {
    final key = apiKey ?? Platform.environment['ANTHROPIC_API_KEY'];
    return {
      'content-type': 'application/json',
      'anthropic-version': _anthropicVersion,
      if (stream) 'accept': 'text/event-stream',
      if (authToken != null) ...{
        'authorization': 'Bearer $authToken',
        'anthropic-beta': 'oauth-2025-04-20',
      } else
        'x-api-key': ?key,
    };
  }

  @override
  Future<ModelResponse> generate(ModelRequest request) async {
    final client = _clientFactory();
    try {
      final response = await client.post(
        Uri.parse('$baseUrl/v1/messages'),
        headers: _headers(),
        body: jsonEncode(
          buildRequestBody(
            request,
            model: targetModel,
            defaultMaxTokens: defaultMaxTokens,
            strictTools: strictTools,
          ),
        ),
      );

      final json = jsonDecode(response.body) as Map<String, dynamic>;
      if (response.statusCode != 200) {
        final error = json['error'] as Map<String, dynamic>?;
        throw StateError(
          'Claude API error ${response.statusCode} '
          '(${error?['type'] ?? 'unknown'}): ${error?['message'] ?? response.body}',
        );
      }
      return parseResponse(json);
    } finally {
      client.close();
    }
  }

  @override
  Stream<ModelResponseChunk> generateStream(ModelRequest request) async* {
    final client = _clientFactory();
    try {
      final httpRequest = http.Request('POST', Uri.parse('$baseUrl/v1/messages'))
        ..headers.addAll(_headers(stream: true))
        ..body = jsonEncode(
          buildRequestBody(
            request,
            model: targetModel,
            defaultMaxTokens: defaultMaxTokens,
            strictTools: strictTools,
            stream: true,
          ),
        );

      final streamed = await client.send(httpRequest);
      if (streamed.statusCode != 200) {
        final body = await streamed.stream.bytesToString();
        throw StateError('Claude API stream error ${streamed.statusCode}: $body');
      }

      FinishReason? finishReason;
      UsageMetadata? usage;
      // Accumulator for a streaming tool_use block's input JSON.
      String? pendingToolId;
      String? pendingToolName;
      final pendingToolJson = StringBuffer();

      final lines = streamed.stream.transform(utf8.decoder).transform(const LineSplitter());

      await for (final line in lines) {
        if (!line.startsWith('data:')) continue;
        final payload = line.substring(5).trim();
        if (payload.isEmpty) continue;

        final event = jsonDecode(payload) as Map<String, dynamic>;
        switch (event['type'] as String?) {
          case 'message_start':
            // Input + cache token counts arrive only here; message_delta
            // carries cumulative output tokens. Seed the accumulator so the
            // terminal chunk reports full prompt usage.
            final message = event['message'] as Map<String, dynamic>? ?? {};
            final rawUsage = message['usage'] as Map<String, dynamic>?;
            if (rawUsage != null) usage = parseUsage(rawUsage);
          case 'content_block_start':
            final block = event['content_block'] as Map<String, dynamic>? ?? {};
            if (block['type'] == 'tool_use') {
              pendingToolId = block['id'] as String? ?? '';
              pendingToolName = block['name'] as String? ?? '';
              pendingToolJson.clear();
            }
          case 'content_block_delta':
            final delta = event['delta'] as Map<String, dynamic>? ?? {};
            switch (delta['type'] as String?) {
              case 'text_delta':
                final text = delta['text'] as String? ?? '';
                if (text.isNotEmpty) {
                  yield ModelResponseChunk(delta: TextPart(text), textDelta: text);
                }
              case 'thinking_delta':
                final thinking = delta['thinking'] as String? ?? '';
                if (thinking.isNotEmpty) {
                  yield ModelResponseChunk(delta: ThoughtPart(thinking));
                }
              case 'input_json_delta':
                pendingToolJson.write(delta['partial_json'] as String? ?? '');
            }
          case 'content_block_stop':
            if (pendingToolName != null) {
              yield ModelResponseChunk(
                delta: FunctionCallPart(
                  callId: pendingToolId ?? '',
                  name: pendingToolName,
                  arguments: _tryDecodeArgs(pendingToolJson.toString()),
                ),
              );
              pendingToolId = null;
              pendingToolName = null;
              pendingToolJson.clear();
            }
          case 'message_delta':
            final delta = event['delta'] as Map<String, dynamic>? ?? {};
            final stopReason = delta['stop_reason'] as String?;
            if (stopReason != null) finishReason = mapStopReason(stopReason);
            final rawUsage = event['usage'] as Map<String, dynamic>?;
            if (rawUsage != null) {
              // Merge, don't overwrite: message_delta usage carries cumulative
              // output_tokens but typically no input/cache counts — keep the
              // prompt side seeded by message_start.
              final deltaUsage = parseUsage(rawUsage);
              final prior = usage;
              usage = prior == null
                  ? deltaUsage
                  : UsageMetadata(
                      promptTokenCount: deltaUsage.promptTokenCount > 0
                          ? deltaUsage.promptTokenCount
                          : prior.promptTokenCount,
                      candidatesTokenCount: deltaUsage.candidatesTokenCount,
                      cacheReadTokenCount: deltaUsage.cacheReadTokenCount > 0
                          ? deltaUsage.cacheReadTokenCount
                          : prior.cacheReadTokenCount,
                      cacheCreationTokenCount: deltaUsage.cacheCreationTokenCount > 0
                          ? deltaUsage.cacheCreationTokenCount
                          : prior.cacheCreationTokenCount,
                      source: UsageSource.measured,
                    );
            }
          case 'message_stop':
            yield ModelResponseChunk(finishReason: finishReason ?? FinishReason.stop, usage: usage);
          case 'error':
            final error = event['error'] as Map<String, dynamic>? ?? {};
            throw StateError('Claude API stream error: ${error['message']}');
        }
      }
    } finally {
      client.close();
    }
  }

  static Map<String, dynamic> _tryDecodeArgs(String raw) {
    if (raw.trim().isEmpty) return const {};
    try {
      return Map<String, dynamic>.from(jsonDecode(raw) as Map);
    } catch (_) {
      return {'_raw': raw};
    }
  }

  // ───────────────────────────────────────────────────────────────────────
  // Request lowering (pure, unit-testable)
  // ───────────────────────────────────────────────────────────────────────

  /// Lowers a typed [ModelRequest] into a Messages API request body.
  static Map<String, dynamic> buildRequestBody(
    ModelRequest request, {
    required String model,
    int defaultMaxTokens = 16000,
    bool strictTools = false,
    bool stream = false,
  }) {
    final config = request.generationConfig;
    final wantsCache = request.cacheHints.isNotEmpty;
    // A hint requesting >= 1h TTL upgrades the breakpoint to the 1h cache.
    final wantsLongTtl = request.cacheHints.any((h) => h.ttl >= const Duration(hours: 1));
    final cacheControl = {'type': 'ephemeral', if (wantsLongTtl) 'ttl': '1h'};

    return {
      'model': model,
      'max_tokens': config.maxOutputTokens ?? defaultMaxTokens,
      if (stream) 'stream': true,
      // System prompt: the stable prefix. When cache hints are present, place
      // a breakpoint here so tools + system cache together (render order is
      // tools -> system -> messages).
      if (request.systemInstruction != null && request.systemInstruction!.text.trim().isNotEmpty)
        'system': [
          {
            'type': 'text',
            'text': request.systemInstruction!.text,
            if (wantsCache) 'cache_control': cacheControl,
          },
        ],
      'messages': lowerMessages(request.messages, cacheConversation: wantsCache, cacheControl: cacheControl),
      if (request.tools.isNotEmpty)
        'tools': [for (final tool in request.tools) lowerTool(tool, strict: strictTools)],
      // Structured outputs: the compiler-level typed return value.
      if (config.responseSchema != null)
        'output_config': {
          'format': {'type': 'json_schema', 'schema': config.responseSchema},
        },
      if (config.stopSequences != null && config.stopSequences!.isNotEmpty)
        'stop_sequences': config.stopSequences,
      // temperature/topP/topK are intentionally NOT forwarded: current Claude
      // models reject non-default sampling parameters.
    };
  }

  /// Lowers Vaster [ChatMessage]s into Messages API message objects.
  ///
  /// Role mapping: `user`->user, `model`->assistant (text/tool_use blocks),
  /// `tool`->user carrying `tool_result` blocks. When [cacheConversation] is
  /// set, the last content block of the *previous* turn gets a breakpoint so
  /// multi-turn conversations reuse their history prefix.
  static List<Map<String, dynamic>> lowerMessages(
    List<ChatMessage> messages, {
    bool cacheConversation = false,
    Map<String, dynamic> cacheControl = const {'type': 'ephemeral'},
  }) {
    final lowered = <Map<String, dynamic>>[];

    for (final message in messages) {
      switch (message.role) {
        case Role.user || Role.system:
          lowered.add({
            'role': 'user',
            'content': [
              for (final part in message.parts)
                if (part is TextPart) {'type': 'text', 'text': part.text},
            ],
          });
        case Role.model:
          lowered.add({
            'role': 'assistant',
            'content': [
              for (final part in message.parts)
                switch (part) {
                  TextPart p => {'type': 'text', 'text': p.text},
                  FunctionCallPart p => {
                    'type': 'tool_use',
                    'id': p.callId,
                    'name': p.name,
                    'input': p.arguments,
                  },
                  _ => null,
                },
            ].whereType<Map<String, dynamic>>().toList(),
          });
        case Role.tool:
          lowered.add({
            'role': 'user',
            'content': [
              for (final part in message.parts)
                if (part is FunctionResponsePart)
                  {'type': 'tool_result', 'tool_use_id': part.callId, 'content': jsonEncode(part.response)},
            ],
          });
      }
    }

    // Multi-turn cache breakpoint: last block of the most recent *completed*
    // turn (i.e. the message before the current user question).
    if (cacheConversation && lowered.length >= 2) {
      final previousTurn = lowered[lowered.length - 2];
      final content = previousTurn['content'] as List;
      if (content.isNotEmpty) {
        final lastBlock = Map<String, dynamic>.from(content.last as Map);
        lastBlock['cache_control'] = cacheControl;
        content[content.length - 1] = lastBlock;
      }
    }

    return lowered;
  }

  /// Lowers a [ToolDefinition] into a Messages API tool object.
  static Map<String, dynamic> lowerTool(ToolDefinition tool, {bool strict = false}) {
    final schema = Map<String, dynamic>.from(tool.parametersSchema);
    if (strict) {
      schema['additionalProperties'] = false;
      schema.putIfAbsent('required', () => ((schema['properties'] as Map?) ?? {}).keys.toList());
    }
    return {
      'name': tool.name,
      'description': tool.description,
      'input_schema': schema,
      if (strict) 'strict': true,
    };
  }

  // ───────────────────────────────────────────────────────────────────────
  // Response parsing (pure, unit-testable)
  // ───────────────────────────────────────────────────────────────────────

  /// Parses a Messages API response into a typed [ModelResponse].
  static ModelResponse parseResponse(Map<String, dynamic> json) {
    final parts = <ContentPart>[];
    for (final raw in (json['content'] as List?) ?? const []) {
      final block = Map<String, dynamic>.from(raw as Map);
      switch (block['type'] as String?) {
        case 'text':
          parts.add(TextPart(block['text'] as String? ?? ''));
        case 'thinking':
          final thinking = block['thinking'] as String? ?? '';
          if (thinking.isNotEmpty) parts.add(ThoughtPart(thinking));
        case 'tool_use':
          parts.add(
            FunctionCallPart(
              callId: block['id'] as String? ?? '',
              name: block['name'] as String? ?? '',
              arguments: Map<String, dynamic>.from(block['input'] as Map? ?? const {}),
            ),
          );
      }
    }

    return ModelResponse(
      message: ChatMessage(role: Role.model, parts: parts),
      finishReason: mapStopReason(json['stop_reason'] as String?),
      usage: parseUsage(json['usage'] as Map<String, dynamic>? ?? const {}),
      rawResponse: json,
    );
  }

  /// Maps a Messages API `stop_reason` to a [FinishReason].
  static FinishReason mapStopReason(String? stopReason) => switch (stopReason) {
    'end_turn' || 'stop_sequence' => FinishReason.stop,
    'max_tokens' || 'model_context_window_exceeded' => FinishReason.maxTokens,
    'tool_use' || 'pause_turn' => FinishReason.toolCalls,
    'refusal' => FinishReason.safety,
    null => FinishReason.unknown,
    _ => FinishReason.unknown,
  };

  /// Parses exact server token usage — including prompt-cache reads/writes,
  /// which are billed as input and must be charged to the budget.
  static UsageMetadata parseUsage(Map<String, dynamic> usage) {
    final input = (usage['input_tokens'] as int?) ?? 0;
    final cacheRead = (usage['cache_read_input_tokens'] as int?) ?? 0;
    final cacheWrite = (usage['cache_creation_input_tokens'] as int?) ?? 0;
    return UsageMetadata(
      // Total prompt size = uncached + cache-read + cache-write tokens
      // (Anthropic's input_tokens excludes cache tokens).
      promptTokenCount: input + cacheRead + cacheWrite,
      candidatesTokenCount: (usage['output_tokens'] as int?) ?? 0,
      cacheReadTokenCount: cacheRead,
      cacheCreationTokenCount: cacheWrite,
      source: UsageSource.measured,
    );
  }
}
