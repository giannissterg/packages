import 'package:args/args.dart';
import 'package:vaster_llama_ffi/vaster_llama_ffi.dart';
import 'package:vaster_model_claude_api/vaster_model_claude_api.dart';
import 'package:vaster_model_claude_cli/vaster_model_claude_cli.dart';
import 'package:vaster_model_fake/vaster_model_fake.dart';
import 'package:vaster_model_gemini_cli/vaster_model_gemini_cli.dart';
import 'package:vaster_model_google_ai/vaster_model_google_ai.dart';
import 'package:vaster_model_rpc/vaster_model_rpc.dart';
import 'package:vaster_vm/vaster_vm.dart';
import 'dart:io' show File, Platform;

import '../vaster_command.dart';
import 'kv_prewarmer.dart';

/// A resolved backend: the model, plus the zero-copy prewarm capability
/// when the backend has one (`llama`) — hosts use it to materialize
/// pinned regions into physical KV state at park time so a resume starts
/// warm. The resolver owns the concrete pairing of controller and
/// renderer; consumers see only the capability.
final class ResolvedBackend {
  final VasterModel model;
  final KvPrewarmer? kvPrewarmer;

  /// Releases resources the RESOLVER acquired (e.g. the llama worker
  /// isolate). The resolver spawned them, the resolver's result owns
  /// their teardown — hosts call this instead of reaching through the
  /// model for internals.
  final Future<void> Function() dispose;

  const ResolvedBackend(this.model, {this.kvPrewarmer, required this.dispose});
}

Future<void> _noDispose() async {}

/// Fallback GGUF used by `--backend llama` when neither `--model` nor
/// `VASTER_LLAMA_MODEL` names one.
String defaultLlamaModelPath() =>
    '${Platform.environment['HOME']}/models/SmolLM2-135M-Instruct-Q4_K_M.gguf';

/// One backend-name → model resolution for every CLI verb (`run`, `resume`).
///
/// Real network backends are wrapped in the resilience layer: transient
/// failures (429/5xx/timeouts) retry with exponential backoff instead of
/// trapping the VM. The in-process `llama` backend is deliberately NOT
/// wrapped: it holds live engine state (a restored KV sequence), and a
/// blind retry would re-decode against that state.
Future<ResolvedBackend> resolveBackendModel({
  required ArgResults results,
  required CommandContext context,
  required StringSink err,
}) async {
  final backend = results['backend'] as String? ?? 'fake';

  VasterModel resilient(VasterModel backend) => ResilientVasterModel(
        primary: backend,
        retryPolicy: const RetryPolicy(
          maxAttempts: 3,
          attemptTimeout: Duration(minutes: 2),
        ),
        onRetry: (event) => err.writeln('  [retry] $event'),
      );

  if (backend == 'llama') {
    final modelPath = results['model'] as String? ??
        Platform.environment['VASTER_LLAMA_MODEL'] ??
        defaultLlamaModelPath();
    if (!File(modelPath).existsSync()) {
      throw StateError('llama backend: model file not found at "$modelPath" '
          '(pass --model <path.gguf> or set VASTER_LLAMA_MODEL).');
    }
    final worker = await LlamaWorker.spawn(modelPath: modelPath);
    final kv = LlamaFfiKvCacheController(worker: worker);
    final stem = modelPath.split('/').last.replaceAll('.gguf', '');
    return ResolvedBackend(
      LlamaFfiVasterModel(
          worker: worker, kvController: kv, modelName: 'llama-ffi:$stem'),
      kvPrewarmer: KvPrewarmer(
        controller: kv,
        // The alignment contract: prewarm renders exactly what this
        // model's prompt composer renders.
        renderMessages: LlamaFfiVasterModel.renderMessages,
      ),
      dispose: worker.close,
    );
  }

  return ResolvedBackend(dispose: _noDispose, switch (backend) {
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
  });
}
