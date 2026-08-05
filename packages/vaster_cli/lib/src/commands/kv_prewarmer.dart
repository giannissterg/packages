import 'package:vaster_context_manager/vaster_context_manager.dart';
import 'package:vaster_kv/vaster_kv.dart';
import 'package:vaster_model/vaster_model.dart';

/// Host-side zero-copy prewarm capability: materializes every pinned
/// context region into physical KV state, keyed by the region's
/// cache-descriptor fingerprint — the same fingerprint the runtime's
/// cache hints carry. A later process (a `vaster resume`, or the next
/// run of the same pipeline) resolves those hints against the state and
/// restores instead of re-decoding the prefix.
///
/// Deliberately built from interfaces only: any [KvCacheController] plus
/// the owning backend's message renderer. [renderMessages] is the
/// alignment contract — it must produce exactly the text the backend's
/// prompt composer will render for those messages, so the materialized
/// state is a token-exact prompt prefix. The concrete pairing (which
/// controller, which renderer) is the backend resolver's business.
///
/// This is a host (CLI) concern, like checkpoint files: the runtime
/// stays unaware of physical KV state.
final class KvPrewarmer {
  final KvCacheController controller;
  final String Function(Iterable<ChatMessage> messages) renderMessages;

  const KvPrewarmer({required this.controller, required this.renderMessages});

  /// Returns `(regionsMaterialized, tokensMaterialized)`.
  Future<(int, int)> prewarmPinnedRegions(ContextManager contextManager) async {
    var regions = 0;
    var tokens = 0;
    for (final region in contextManager.regions) {
      if (!region.isPinned) continue;
      final descriptor = contextManager.getCacheDescriptor(region.id);
      if (descriptor == null) continue;
      if (await controller.lookup(descriptor.contentFingerprint) != null) {
        continue; // already materialized (this run or a previous process)
      }
      final rendered = renderMessages(region.messages);
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
}
