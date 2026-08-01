import 'package:vaster_model/vaster_model.dart';
import 'context_region.dart';
import 'token_budget.dart';

/// Immutable payload produced when a virtual context heap is compiled for model execution.
class CompiledContext {
  /// Top-level system instruction message, if present.
  final ChatMessage? systemInstruction;

  /// Ordered list of chat messages compiled from active context regions within budget.
  final List<ChatMessage> messages;

  /// Total estimated tokens consumed by compiled messages.
  final int totalEstimatedTokens;

  /// The token budget configured for this compilation.
  final TokenBudget budget;

  /// List of context regions included in the compilation.
  final List<ContextRegion> includedRegions;

  /// List of context regions evicted during compilation to fit budget constraints.
  final List<ContextRegion> evictedRegions;

  const CompiledContext({
    required this.messages,
    required this.totalEstimatedTokens,
    required this.budget,
    this.systemInstruction,
    this.includedRegions = const [],
    this.evictedRegions = const [],
  });

  @override
  String toString() =>
      'CompiledContext(messages: ${messages.length}, tokens: ~$totalEstimatedTokens, includedRegions: ${includedRegions.length}, evictedRegions: ${evictedRegions.length})';
}
