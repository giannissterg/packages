import 'package:vaster_events/vaster_events.dart';
import 'package:vaster_model/vaster_model.dart';

import 'model_registry.dart';

/// Resolves a declared model chain (primary + ordered fallbacks) into a
/// live model — THE one composer for both consumers (the runtime's active
/// model and the VM's agent creation), which previously carried 22-line
/// verbatim twins of this logic with a shared latent bug.
///
/// Semantics (REL-P3/GAP-3b): members resolve through the registry;
/// unresolvable fallbacks are skipped; the chain composes as a
/// one-attempt [ResilientVasterModel] — each member tried once,
/// model-kind failures advance (publishing a [ModelFallbackEvent] per
/// hop), cancellation never advances, and the serving member stamps
/// `servedBy` for attribution. Retrying the SAME model is `Resilient`'s
/// compiled loop, never the chain's job.
///
/// The next-hop lookup is INDEX-exact ([ModelRetryEvent.modelIndex]) — a
/// chain containing the same model name twice reports its hops correctly,
/// which the old name-based `indexOf` lookup did not.
final class ModelChainResolver {
  final ModelRegistry registry;
  final RuntimeEventBus eventBus;

  const ModelChainResolver({required this.registry, required this.eventBus});

  /// Resolves [primary]+[fallbacks]; null when [primary] is null or
  /// unresolvable. [eventScope] discriminates this chain's fallback
  /// events (e.g. `pc_12`, `agent_worker`).
  VasterModel? resolve({
    required ModelDescriptor? primary,
    required List<ModelDescriptor> fallbacks,
    required String eventScope,
  }) {
    if (primary == null) return null;
    final resolvedPrimary = registry.resolveModel(primary);
    if (resolvedPrimary == null || fallbacks.isEmpty) return resolvedPrimary;
    final resolvedFallbacks = [
      for (final f in fallbacks) registry.resolveModel(f),
    ].whereType<VasterModel>().toList();
    if (resolvedFallbacks.isEmpty) return resolvedPrimary;
    final chainNames = [
      resolvedPrimary.modelName,
      for (final f in resolvedFallbacks) f.modelName,
    ];
    return ResilientVasterModel(
      primary: resolvedPrimary,
      fallbacks: resolvedFallbacks,
      retryPolicy: const RetryPolicy(maxAttempts: 1),
      onRetry: (event) {
        if (!event.switchingModel) return;
        eventBus.publish(ModelFallbackEvent(
          eventId: 'evt_fallback_${eventScope}_${event.modelIndex}',
          fromModel: event.modelName,
          toModel: event.modelIndex + 1 < chainNames.length
              ? chainNames[event.modelIndex + 1]
              : '',
          reason: '${event.error}',
        ));
      },
    );
  }
}
