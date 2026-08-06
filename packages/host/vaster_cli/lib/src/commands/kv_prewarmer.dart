import 'package:vaster_context_manager/vaster_context_manager.dart';
import 'package:vaster_context_mmu/vaster_context_mmu.dart';
import 'package:vaster_kv/vaster_kv.dart';
import 'package:vaster_model/vaster_model.dart';

/// Host-side zero-copy prewarm capability: materializes every pinned
/// context region into physical KV state at park time, so a later
/// process (a `vaster resume`, or the next run of the same pipeline)
/// restores those hints instead of re-decoding the prefix.
///
/// A thin delegation over [ContextMmu] — the page table owns the
/// hit/fault/invalidation logic (this class used to duplicate the bind
/// loop minus invalidation). The backend's [renderMessages] is injected
/// as the MMU's content renderer: the alignment contract requiring the
/// materialized payload to be a token-exact prefix of the prompts the
/// backend composes.
///
/// This is deliberately a host (CLI) concern, like checkpoint files:
/// the runtime stays unaware of physical KV state.
final class KvPrewarmer {
  final ContextMmu _mmu;

  KvPrewarmer({
    required KvCacheController controller,
    required String Function(Iterable<ChatMessage> messages) renderMessages,
  }) : _mmu = ContextMmu(
          controller: controller,
          contentRenderer: (region) => renderMessages(region.messages),
        );

  /// Binds every pinned region to physical state, materializing on
  /// fault. Returns the pass's [MmuStats] for the host to report.
  Future<MmuStats> prewarmPinnedRegions(ContextManager contextManager) async {
    final stats = MmuStats();
    await _mmu.bindPinnedRegions(contextManager, stats: stats);
    return stats;
  }
}
