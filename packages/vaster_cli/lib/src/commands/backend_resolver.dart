import 'package:args/args.dart';
import 'package:vaster_model_claude_api/vaster_model_claude_api.dart';
import 'package:vaster_model_claude_cli/vaster_model_claude_cli.dart';
import 'package:vaster_model_fake/vaster_model_fake.dart';
import 'package:vaster_model_gemini_cli/vaster_model_gemini_cli.dart';
import 'package:vaster_model_google_ai/vaster_model_google_ai.dart';
import 'package:vaster_model_rpc/vaster_model_rpc.dart';
import 'package:vaster_vm/vaster_vm.dart';
import 'dart:io' show Platform;

import '../vaster_command.dart';

/// One backend-name → model resolution for every CLI verb (`run`, `resume`).
///
/// Real network backends are wrapped in the resilience layer: transient
/// failures (429/5xx/timeouts) retry with exponential backoff instead of
/// trapping the VM.
VasterModel resolveBackendModel({
  required ArgResults results,
  required CommandContext context,
  required StringSink err,
}) {
  final backend = results['backend'] as String? ?? 'fake';

  VasterModel resilient(VasterModel backend) => ResilientVasterModel(
        primary: backend,
        retryPolicy: const RetryPolicy(
          maxAttempts: 3,
          attemptTimeout: Duration(minutes: 2),
        ),
        onRetry: (event) => err.writeln('  [retry] $event'),
      );

  return switch (backend) {
    'claude-api' => resilient(ClaudeApiVasterModel(
        targetModel: results['model'] as String? ?? 'claude-opus-5')),
    'claude-cli' => resilient(ClaudeCliVasterModel(
        selectedModel: results['model'] as String?,
        workingDirectory: context.workingDirectory)),
    'gemini' => resilient(GoogleAiVasterModel(
        apiKey: Platform.environment['GEMINI_API_KEY'] ??
            Platform.environment['GOOGLE_AI_API_KEY'],
        targetModel: results['model'] as String? ?? 'gemini-2.0-flash')),
    'gemini-cli' => resilient(GeminiCliVasterModel(
        selectedModel: results['model'] as String?,
        workingDirectory: context.workingDirectory)),
    'rpc' => resilient(RpcVasterModel(socketPath: context.socketPath)),
    _ => FakeVasterModel(),
  };
}
