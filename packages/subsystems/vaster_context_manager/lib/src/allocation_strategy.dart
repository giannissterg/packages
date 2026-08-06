import 'package:vaster_context/vaster_context.dart';
import 'package:vaster_model/vaster_model.dart';

/// Strategy interface for allocating token budgets and selecting/evicting context regions.
abstract interface class AllocationStrategy {
  /// Allocates tokens across [regions] within [budget], returning a [CompiledContext].
  CompiledContext allocate({
    required List<ContextRegion> regions,
    required TokenBudget budget,
  });
}

/// Default allocation strategy prioritizing regions by [ContextPriority] (critical -> high -> medium -> low -> ephemeral)
/// and utility score, evicting lowest priority regions when token limits are exceeded.
class PriorityAllocationStrategy implements AllocationStrategy {
  const PriorityAllocationStrategy();

  @override
  CompiledContext allocate({
    required List<ContextRegion> regions,
    required TokenBudget budget,
  }) {
    // Sort regions by priority descending, then utility descending
    final sortedRegions = List<ContextRegion>.from(regions)
      ..sort((a, b) {
        final prioDiff =
            b.priorityOrDefault.index.compareTo(a.priorityOrDefault.index);
        if (prioDiff != 0) return prioDiff;
        return b.utility.compareTo(a.utility);
      });

    final included = <ContextRegion>[];
    final evicted = <ContextRegion>[];
    final evictionRecords = <EvictionRecord>[];
    var currentTokens = 0;
    final maxInputTokens = budget.availableInputBudget;

    ChatMessage? systemInstruction;

    for (final region in sortedRegions) {
      // Extract system instructions if any
      final sysMsg = region.messages.where((m) => m.role == Role.system).firstOrNull;
      if (sysMsg != null && systemInstruction == null) {
        systemInstruction = sysMsg;
      }

      if (region.isPinned ||
          currentTokens + region.estimatedTokens <= maxInputTokens ||
          region.priority == ContextPriority.critical) {
        included.add(region);
        currentTokens += region.estimatedTokens;
      } else {
        evicted.add(region);
        evictionRecords.add(EvictionRecord(
          regionId: region.id,
          reason: EvictionReason.budgetExceeded,
          regionTokens: region.estimatedTokens,
          tokensAvailableAtDecision:
              (maxInputTokens - currentTokens).clamp(0, maxInputTokens),
        ));
      }
    }

    // Flatten compiled messages. Selection above is priority-driven, but
    // RENDERING follows each region's `order` hint (stable sort — regions
    // with equal order keep their selection sequence). History chunks use
    // large order values so conversation turns always render last,
    // chronologically.
    final renderOrder = List<ContextRegion>.of(included);
    _stableSortByOrder(renderOrder);

    final compiledMessages = <ChatMessage>[];
    for (final region in renderOrder) {
      for (final msg in region.messages) {
        if (msg.role != Role.system) {
          compiledMessages.add(msg);
        }
      }
    }

    return CompiledContext(
      systemInstruction: systemInstruction,
      messages: compiledMessages,
      totalEstimatedTokens: currentTokens,
      budget: budget,
      includedRegions: included,
      evictedRegions: evicted,
      evictionRecords: evictionRecords,
    );
  }

  /// Insertion sort by `order` — stable, and lists here are small.
  static void _stableSortByOrder(List<ContextRegion> regions) {
    for (var i = 1; i < regions.length; i++) {
      final current = regions[i];
      var j = i - 1;
      while (j >= 0 && regions[j].order > current.order) {
        regions[j + 1] = regions[j];
        j--;
      }
      regions[j + 1] = current;
    }
  }
}
