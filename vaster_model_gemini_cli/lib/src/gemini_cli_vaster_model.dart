import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:vaster_model/vaster_model.dart';

/// An implementation of [VasterModel] that invokes the local Gemini CLI (`gemini`)
/// binary as an LLM backend.
class GeminiCliVasterModel implements VasterModel {
  /// Path or command name for the Gemini CLI binary.
  final String executablePath;

  /// Optional model name passed to Gemini CLI via `--model` / `-m`.
  final String? selectedModel;

  /// Additional command-line flags or arguments passed to Gemini CLI.
  final List<String> extraArgs;

  /// Working directory for process execution.
  final String? workingDirectory;

  @override
  final String modelName;

  @override
  final ModelCapabilities capabilities;

  GeminiCliVasterModel({
    this.executablePath = 'gemini',
    this.selectedModel,
    this.extraArgs = const ['--approval-mode', 'yolo'],
    this.workingDirectory,
    this.modelName = 'gemini-cli',
    this.capabilities = const ModelCapabilities(
      maxContextTokens: 128000,
      maxOutputTokens: 8192,
      supportsStreaming: true,
      supportsFunctionCalling: false,
      supportsVision: true,
      supportsSystemInstruction: true,
      supportsReasoning: true,
    ),
  });

  @override
  Future<ModelResponse> generate(ModelRequest request) async {
    final prompt = _buildPrompt(request);
    final args = _buildCliArgs(prompt: prompt, outputFormat: 'json');

    final result = await Process.run(
      executablePath,
      args,
      workingDirectory: workingDirectory,
      runInShell: true,
    );

    if (result.exitCode != 0) {
      final errorMsg = _extractErrorMessage(result.stdout.toString(), result.stderr.toString());
      throw StateError(
        'Gemini CLI failed with exit code ${result.exitCode}: $errorMsg',
      );
    }

    return _parseJsonResponse(result.stdout.toString());
  }

  @override
  Stream<ModelResponseChunk> generateStream(ModelRequest request) async* {
    final prompt = _buildPrompt(request);
    final args = _buildCliArgs(prompt: prompt, outputFormat: 'stream-json');

    final process = await Process.start(
      executablePath,
      args,
      workingDirectory: workingDirectory,
      runInShell: true,
    );

    // Close stdin immediately so gemini does not wait for stdin EOF
    await process.stdin.close();

    final lineStream = process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter());

    await for (final line in lineStream) {
      final trimmed = line.trim();
      if (trimmed.isEmpty || !trimmed.startsWith('{')) continue;

      try {
        final json = jsonDecode(trimmed) as Map<String, dynamic>;

        if (json.containsKey('error')) {
          final errMap = json['error'] as Map<String, dynamic>?;
          final msg = errMap?['message'] as String? ?? 'Unknown error';
          throw StateError('Gemini CLI streaming error: $msg');
        }

        final type = json['type'] as String?;

        if (type == 'message') {
          final content = json['content'] as String? ?? '';
          if (content.isNotEmpty) {
            yield ModelResponseChunk(
              delta: TextPart(content),
              textDelta: content,
            );
          }
        } else if (type == 'result') {
          final stats = json['stats'] as Map<String, dynamic>?;
          UsageMetadata? usage;

          if (stats != null) {
            final inputTokens = stats['input_tokens'] as int? ?? 0;
            final outputTokens = stats['output_tokens'] as int? ?? 0;
            usage = UsageMetadata(
              promptTokenCount: inputTokens,
              candidatesTokenCount: outputTokens,
            );
          }

          yield ModelResponseChunk(
            finishReason: FinishReason.stop,
            usage: usage,
          );
        }
      } catch (e) {
        if (e is StateError) rethrow;
        // Skip non-JSON output lines (e.g. CLI warnings or diagnostic logs)
      }
    }

    final exitCode = await process.exitCode;
    if (exitCode != 0) {
      final stderrText = await process.stderr.transform(utf8.decoder).join();
      throw StateError(
        'Gemini CLI stream failed with exit code $exitCode: ${stderrText.trim()}',
      );
    }
  }

  /// Builds command-line arguments for Gemini CLI process execution.
  List<String> _buildCliArgs({
    required String prompt,
    required String outputFormat,
  }) {
    return [
      '-p',
      prompt,
      '-o',
      outputFormat,
      if (selectedModel != null) ...['-m', selectedModel!],
      ...extraArgs,
    ];
  }

  /// Formats the [ModelRequest] into a single composite prompt string.
  String _buildPrompt(ModelRequest request) {
    final buffer = StringBuffer();

    if (request.systemInstruction != null &&
        request.systemInstruction!.text.trim().isNotEmpty) {
      buffer.writeln('System Instruction:');
      buffer.writeln(request.systemInstruction!.text.trim());
      buffer.writeln();
    }

    for (final message in request.messages) {
      buffer.writeln('${message.role.name}: ${message.text}');
    }

    return buffer.toString().trim();
  }

  /// Extracts and parses the JSON response body from Gemini CLI stdout.
  ModelResponse _parseJsonResponse(String stdoutText) {
    final jsonStartIndex = stdoutText.indexOf('{');
    final jsonEndIndex = stdoutText.lastIndexOf('}');

    if (jsonStartIndex == -1 || jsonEndIndex == -1 || jsonEndIndex < jsonStartIndex) {
      throw FormatException(
        'Could not locate valid JSON in Gemini CLI stdout:\n$stdoutText',
      );
    }

    final jsonSubstring = stdoutText.substring(jsonStartIndex, jsonEndIndex + 1);
    final json = jsonDecode(jsonSubstring) as Map<String, dynamic>;

    if (json.containsKey('error')) {
      final errMap = json['error'] as Map<String, dynamic>?;
      final msg = errMap?['message'] as String? ?? 'Gemini CLI error';
      throw StateError('Gemini CLI error: $msg');
    }

    final responseText = json['response'] as String? ?? '';
    final stats = json['stats'] as Map<String, dynamic>?;

    UsageMetadata usage = const UsageMetadata();
    if (stats != null && stats['models'] is Map) {
      final modelsMap = stats['models'] as Map<String, dynamic>;
      var totalInput = 0;
      var totalOutput = 0;

      for (final modelEntry in modelsMap.values) {
        if (modelEntry is Map && modelEntry['tokens'] is Map) {
          final tokens = modelEntry['tokens'] as Map<String, dynamic>;
          totalInput += (tokens['prompt'] as int? ?? tokens['input'] as int? ?? 0);
          totalOutput += (tokens['candidates'] as int? ?? tokens['output'] as int? ?? 0);
        }
      }

      usage = UsageMetadata(
        promptTokenCount: totalInput,
        candidatesTokenCount: totalOutput,
      );
    }

    return ModelResponse(
      message: ChatMessage.model(responseText),
      finishReason: FinishReason.stop,
      usage: usage,
    );
  }

  String _extractErrorMessage(String stdoutText, String stderrText) {
    try {
      final jsonStart = stdoutText.indexOf('{');
      final jsonEnd = stdoutText.lastIndexOf('}');
      if (jsonStart != -1 && jsonEnd > jsonStart) {
        final json = jsonDecode(stdoutText.substring(jsonStart, jsonEnd + 1))
            as Map<String, dynamic>;
        if (json.containsKey('error')) {
          final errMap = json['error'] as Map<String, dynamic>?;
          return errMap?['message'] as String? ?? stderrText;
        }
      }
    } catch (_) {}

    return stderrText.trim().isNotEmpty ? stderrText.trim() : 'Unknown error';
  }
}
