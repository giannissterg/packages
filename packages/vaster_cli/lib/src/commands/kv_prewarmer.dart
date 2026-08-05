import 'package:vaster_context_manager/vaster_context_manager.dart';
import 'package:vaster_llama_ffi/vaster_llama_ffi.dart';

/// Host-side zero-copy prewarm: materializes every pinned context
/// region's **model-rendered** form into a shared KV frame, keyed by the
/// region's cache-descriptor fingerprint — the same fingerprint the
/// runtime's cache hints carry. A later process (a `vaster resume`, or
/// the next run of the same pipeline) resolves those hints against the
/// frames and restores real KV state instead of re-decoding the prefix.
///
/// Rendering goes through [LlamaFfiVasterModel.renderMessages] — the
/// alignment contract: the materialized text must be a byte-identical
/// prefix of the prompt the model will compose.
///
/// This is deliberately a host (CLI) concern: the runtime stays unaware
/// of physical KV state, exactly as it is unaware of checkpoint files.
Future<(int regions, int tokens)> prewarmPinnedRegions({
  required ContextManager contextManager,
  required LlamaFfiKvCacheController controller,
}) async {
  var regions = 0;
  var tokens = 0;
  for (final region in contextManager.regions) {
    if (!region.isPinned) continue;
    final descriptor = contextManager.getCacheDescriptor(region.id);
    if (descriptor == null) continue;
    if (await controller.lookup(descriptor.contentFingerprint) != null) {
      continue; // already materialized (this run or a previous process)
    }
    final rendered = LlamaFfiVasterModel.renderMessages(region.messages);
    if (rendered.isEmpty) continue;
    final handle = await controller.materialize(
      contentFingerprint: descriptor.contentFingerprint,
      content: rendered,
    );
    regions++;
    tokens += handle.tokenCount;
  }
  return (regions, tokens);
}
