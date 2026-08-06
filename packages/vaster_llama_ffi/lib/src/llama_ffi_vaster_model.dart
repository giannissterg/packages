import 'package:vaster_mmap/vaster_mmap.dart';
import 'package:vaster_model/vaster_model.dart';

import 'llama_worker.dart';

/// [VasterModel] backed by in-process llama.cpp inference ([LlamaWorker])
/// with zero-copy KV reuse through shared-memory frames.
///
/// Cache hints are honored physically: a hint whose fingerprint resolves
/// through the [frameResolver] restores real KV state from an attached
/// frame's pages, and only the prompt's remainder is decoded. Usage is
/// engine-measured — `cacheReadTokenCount` is the number of prompt tokens
/// whose decode was skipped because their state came from the frame.
///
/// ### Prefix trust boundary
/// KV state is positional: reuse assumes the composed prompt's leading
/// `tokenCount` tokens equal the materialized content's tokens.
/// [composePrompt] renders stable content (system instruction, earlier
/// turns) first to keep prefixes byte-identical across calls — the same
/// convention as the HTTP backend. Token-exact prefix validation arrives
/// with the ContextMmu wiring (ZC-P5); until then a mismatched hint
/// produces a wrong-context completion, not a crash, and only if its
/// fingerprint collides — fingerprints are content hashes, so honest
/// hints are safe.
final class LlamaFfiVasterModel implements VasterModel {
  final LlamaWorker worker;

  /// Resolves cache-hint fingerprints to named KV frames (typically the
  /// backend's `LlamaFfiKvCacheController` — but only the narrow
  /// resolver contract is needed here). When present, resolving hints
  /// restore real KV state; when null, hints are ignored and every call
  /// decodes cold — the same optional-collaborator shape as
  /// `MmapVasterModel.frameResolver`.
  final KvFrameResolver? frameResolver;

  @override
  final String modelName;

  @override
  final ModelCapabilities capabilities;

  /// Generation cap when the request's `GenerationConfig` doesn't set one.
  final int defaultMaxOutputTokens;

  LlamaFfiVasterModel({
    required this.worker,
    this.frameResolver,
    this.modelName = 'llama-ffi',
    int maxContextTokens = 2048,
    this.defaultMaxOutputTokens = 256,
  }) : capabilities = ModelCapabilities(
          maxContextTokens: maxContextTokens,
          maxOutputTokens: defaultMaxOutputTokens,
          supportsStreaming: true,
          supportsFunctionCalling: false,
          supportsVision: false,
          supportsSystemInstruction: true,
          supportsReasoning: false,
          reportsCostUsd: false,
        );

  /// Renders a message run exactly as it appears inside [composePrompt].
  ///
  /// This is the alignment contract for KV prewarming: state materialized
  /// from `renderMessages(region.messages)` is a byte-identical prefix of
  /// a prompt whose leading messages are that region's — so a restored
  /// frame lines up with the composed prompt token-for-token.
  static String renderMessages(Iterable<ChatMessage> messages) {
    final buffer = StringBuffer();
    for (final message in messages) {
      final text = message.text.trim();
      if (text.isEmpty) continue;
      buffer.writeln('${message.role.name}: $text');
    }
    return buffer.toString();
  }

  /// Flattens the typed conversation into a plain prompt. Stable content
  /// (system instruction, earlier turns) renders first so materialized
  /// prefixes stay byte-identical across calls — required for KV reuse.
  static String composePrompt(ModelRequest request) {
    final buffer = StringBuffer();
    final system = request.systemInstruction?.text.trim();
    if (system != null && system.isNotEmpty) {
      buffer.writeln(system);
      buffer.writeln();
    }
    buffer.write(renderMessages(request.messages));
    buffer.write('model:');
    return buffer.toString();
  }

  @override
  Future<ModelResponse> generate(ModelRequest request) async {
    final prompt = composePrompt(request);

    // Physical cache restore: the first hint whose frame exists wins. The
    // frame NAME is resolved here; the restore itself happens inside the
    // worker's single atomic generate op (an incompatible frame degrades
    // to a cold decode there).
    String? restoreFrame;
    final kv = frameResolver;
    if (kv != null) {
      for (final hint in request.cacheHints) {
        final ref = await kv.resolveFrame(hint.contentFingerprint);
        if (ref != null) {
          restoreFrame = ref.frameName;
          break;
        }
      }
    }

    final maxTokens =
        request.generationConfig.maxOutputTokens ?? defaultMaxOutputTokens;
    final (promptTokens, reusedTokens, text, generatedTokens, hitLimit) =
        await worker.runGenerate(
            text: prompt, maxTokens: maxTokens, restoreFrame: restoreFrame);

    return ModelResponse(
      message: ChatMessage.model(text),
      finishReason: hitLimit ? FinishReason.maxTokens : FinishReason.stop,
      usage: UsageMetadata(
        promptTokenCount: promptTokens,
        candidatesTokenCount: generatedTokens,
        cacheReadTokenCount: reusedTokens,
        source: UsageSource.measured,
      ),
    );
  }

  @override
  Stream<ModelResponseChunk> generateStream(ModelRequest request) async* {
    // One cumulative chunk — honest streaming (token-by-token across the
    // isolate channel) is deferred until something needs it.
    final response = await generate(request);
    yield ModelResponseChunk(
      textDelta: response.text,
      finishReason: response.finishReason,
      usage: response.usage,
    );
  }
}
