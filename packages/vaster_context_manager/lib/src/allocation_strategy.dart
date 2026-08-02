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
        final prioDiff = b.priority.index.compareTo(a.priority.index);
        if (prioDiff != 0) return prioDiff;
        return b.utility.compareTo(a.utility);
      });

    final included = <ContextRegion>[];
    final evicted = <ContextRegion>[];
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
      }
    }

    // Flatten compiled messages
    final compiledMessages = <ChatMessage>[];
    for (final region in included) {
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
    );
  }
}
