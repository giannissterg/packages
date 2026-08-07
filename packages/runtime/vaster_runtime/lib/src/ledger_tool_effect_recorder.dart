import 'package:vaster_events/vaster_events.dart';
import 'package:vaster_tool/vaster_tool.dart';
import 'package:vaster_vm_api/vaster_vm_api.dart';

import 'effect_ledger.dart';

/// The runtime's implementation of the [ToolEffectRecorder] contract
/// (GAP-3a, shared by BOTH tool loops since A1): claims delegate into
/// the [EffectLedger], so every tool call shares the machine's dedup
/// memory — scoped by
/// the dispatch's [EffectRegion], reset by `MarkEffectRetryOp`, discarded
/// with the effect scope, and serialized with the checkpoint.
///
/// Policy lives here, not in the contract: VFS syscalls are compensable
/// (the transaction machinery rolls them back), so they claim inert and
/// always re-execute; and with no active region or scope, claims are
/// inert passthroughs. Every replay publishes a typed
/// [ToolCallReplayedEvent] — a deduped effect is never silent.
final class LedgerToolEffectRecorder implements ToolEffectRecorder {
  final EffectLedger ledger;
  final RuntimeEventBus eventBus;

  const LedgerToolEffectRecorder({required this.ledger, required this.eventBus});

  @override
  ToolEffectClaim claim({
    required EffectRegion region,
    required String name,
    required Map<String, dynamic> arguments,
    String? callId,
  }) {
    if (!region.isActive || !ledger.inScope) return const ToolEffectInert();
    if (name == VfsSyscalls.writeFileName || name == VfsSyscalls.readFileName) {
      return const ToolEffectInert();
    }
    final slot = ledger.claim(name: '${region.key}#$name', arguments: arguments);
    final recorded = slot.recorded;
    if (recorded != null) {
      eventBus.publish(
        ToolCallReplayedEvent(
          eventId: 'evt_tool_replay_${callId ?? name}',
          callId: callId ?? '',
          toolName: name,
        ),
      );
      return ToolEffectReplay(recorded);
    }
    return ToolEffectSlot(slot);
  }

  @override
  Map<String, dynamic> commit(ToolEffectSlot slot, Map<String, dynamic> result) =>
      ledger.commit(slot.token as EffectClaim, result);
}
