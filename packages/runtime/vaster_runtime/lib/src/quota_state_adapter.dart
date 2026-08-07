import 'package:vaster_machine_state/vaster_machine_state.dart';
import 'package:vaster_resources/vaster_resources.dart';

/// Snapshot adapter for the program-declared quota scope.
///
/// [ResourceTracker] lives in `vaster_resources`, which must not know the
/// machine-state contract exists (Rule 6) — the adapter composes the tracker
/// into the machine's component list from the runtime's side. Restore sets
/// raw counters WITHOUT quota checks: the values were legal when captured,
/// and a resume must not re-trip a quota the original run already survived.
final class QuotaStateAdapter implements MachineStateComponent {
  final ResourceTracker tracker;

  const QuotaStateAdapter(this.tracker);

  @override
  String get stateKey => 'quota';

  @override
  Map<String, dynamic> captureState() => {
    'quota': tracker.quota.toJson(),
    'consumedTokens': tracker.consumedTokens,
    'consumedCost': tracker.consumedCost,
    'toolCalls': tracker.toolCallCount,
  };

  @override
  void restoreState(Map<String, dynamic> snapshot) {
    tracker.applyQuota(
      ResourceQuota.fromJson(Map<String, dynamic>.from(snapshot['quota'] as Map? ?? const {})),
    );
    tracker.restoreConsumed(
      tokens: (snapshot['consumedTokens'] as num?)?.toInt() ?? 0,
      cost: (snapshot['consumedCost'] as num?)?.toDouble() ?? 0.0,
      toolCalls: (snapshot['toolCalls'] as num?)?.toInt() ?? 0,
    );
  }
}
