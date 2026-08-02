import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:vaster_model/vaster_model.dart';

/// A [VasterModel] backend that drives the local **Claude Code CLI** (`claude`)
/// in non-interactive print mode as an LLM.
///
/// It shells out to `claude -p <prompt> --output-format json`, which returns a
/// single JSON result object of the form:
///
/// ```json
/// {
///   "type": "result",
///   "subtype": "success",
///   "is_error": false,
///   "result": "<assistant text>",
///   "usage": { "input_tokens": 12, "output_tokens": 34, ... }
/// }
/// ```
///
/// The `claude` binary must be installed and authenticated (`claude` once
/// interactively, or an API key configured). Because it is itself a
/// [VasterModel], it is fully substitutable anywhere in Vaster — including
/// behind a [VasterModelSidecarServer], letting a Vaster VM run against Claude
/// over the RPC sidecar just like any other model.
class ClaudeCliVasterModel implements VasterModel {
  /// Path or command name for the Claude Code CLI binary.
  final String executablePath;

  /// Optional model name passed to the CLI via `--model` (e.g. `sonnet`, `opus`).
  final String? selectedModel;

  /// Additional command-line flags appended to every invocation.
  final List<String> extraArgs;

  /// Working directory for the CLI process (affects its project context).
  final String? workingDirectory;

  @override
  final String modelName;

  @override
  final ModelCapabilities capabilities;

  ClaudeCliVasterModel({
    this.executablePath = 'claude',
    this.selectedModel,
    this.extraArgs = const [],
    this.workingDirectory,
    this.modelName = 'claude-cli',
    this.capabilities = const ModelCapabilities(
      maxContextTokens: 200000,
      maxOutputTokens: 8192,
      supportsStreaming: true,
      // Print-mode JSON does not surface structured tool calls we can parse,
      // so function calling is disabled for this backend.
      supportsFunctionCalling: false,
      supportsVision: false,
      supportsSystemInstruction: true,
      supportsReasoning: true,
    ),
  });

  @override
  Future<ModelResponse> generate(ModelRequest request) async {
    final prompt = composePrompt(request);
    final systemText = request.systemInstruction?.text.trim() ?? '';

    final args = <String>[
      '-p', prompt,
      '--output-format', 'json',
      if (selectedModel != null) ...['--model', selectedModel!],
      if (systemText.isNotEmpty) ...['--append-system-prompt', systemText],
      ...extraArgs,
    ];

    final result = await Process.run(
      executablePath,
      args,
      workingDirectory: workingDirectory,
    );

    if (result.exitCode != 0) {
      final stderr = result.stderr.toString().trim();
      // Even on failure the CLI usually emits a JSON result on stdout; prefer
      // its message, falling back to stderr.
      try {
        return parseCliJson(result.stdout.toString());
      } on StateError {
        rethrow;
      } catch (_) {
        throw StateError(
          'Claude CLI failed with exit code ${result.exitCode}: '
          '${stderr.isNotEmpty ? stderr : 'no output'}',
        );
      }
    }

    return parseCliJson(result.stdout.toString());
  }

  /// Streaming is emulated over the single-shot print call: the full completion
  /// is fetched, then emitted as one text chunk followed by a terminal chunk.
  @override
  Stream<ModelResponseChunk> generateStream(ModelRequest request) async* {
    final response = await generate(request);
    final text = response.text;
    if (text.isNotEmpty) {
      yield ModelResponseChunk(delta: TextPart(text), textDelta: text);
    }
    yield ModelResponseChunk(
      finishReason: response.finishReason,
      usage: response.usage,
    );
  }

  /// Flattens a [ModelRequest]'s conversation into a single prompt string.
  ///
  /// The system instruction is delivered separately via `--append-system-prompt`
  /// and is therefore not included here.
  static String composePrompt(ModelRequest request) {
    final buffer = StringBuffer();
    for (final message in request.messages) {
      final text = message.text.trim();
      if (text.isEmpty) continue;
      buffer.writeln('${message.role.name}: $text');
    }
    return buffer.toString().trim();
  }

  /// Parses the JSON object emitted by `claude -p --output-format json`.
  ///
  /// Throws [StateError] when the CLI reports `is_error: true`, and
  /// [FormatException] when no JSON object can be located in [stdoutText].
  static ModelResponse parseCliJson(String stdoutText) {
    final start = stdoutText.indexOf('{');
    final end = stdoutText.lastIndexOf('}');
    if (start == -1 || end == -1 || end < start) {
      throw FormatException(
        'Could not locate valid JSON in Claude CLI output:\n$stdoutText',
      );
    }

    final json =
        jsonDecode(stdoutText.substring(start, end + 1)) as Map<String, dynamic>;

    final text = json['result'] as String? ?? '';
    final isError = json['is_error'] as bool? ?? false;
    if (isError) {
      throw StateError('Claude CLI error: ${text.isEmpty ? 'unknown error' : text}');
    }

    final usageRaw = json['usage'] as Map<String, dynamic>?;
    final usage = usageRaw == null
        ? const UsageMetadata()
        : UsageMetadata(
            promptTokenCount: (usageRaw['input_tokens'] as int?) ?? 0,
            candidatesTokenCount: (usageRaw['output_tokens'] as int?) ?? 0,
          );

    return ModelResponse(
      message: ChatMessage.model(text),
      finishReason: FinishReason.stop,
      usage: usage,
    );
  }
}
