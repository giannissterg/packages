import 'package:vaster_model/vaster_model.dart';
import 'context_region.dart';
import 'eviction_record.dart';
import 'token_budget.dart';

/// Per-class admission statistics for one compilation — the segment map of
/// the compiled context.
class ContextClassUsage {
  final int admittedRegions;
  final int admittedTokens;
  final int evictedRegions;
  final int evictedTokens;

  const ContextClassUsage({
    this.admittedRegions = 0,
    this.admittedTokens = 0,
    this.evictedRegions = 0,
    this.evictedTokens = 0,
  });

  Map<String, dynamic> toJson() => {
        'admittedRegions': admittedRegions,
        'admittedTokens': admittedTokens,
        if (evictedRegions != 0) 'evictedRegions': evictedRegions,
        if (evictedTokens != 0) 'evictedTokens': evictedTokens,
      };

  @override
  String toString() =>
      '$admittedRegions regions/~$admittedTokens tok'
      '${evictedRegions != 0 ? ' (-$evictedRegions/-$evictedTokens)' : ''}';
}

/// Thrown when a class whose eviction policy is `never` (or whose members are
/// pinned) cannot fit inside the window — silently truncating it would be
/// dishonest, so allocation fails loudly instead.
class ContextOverflowError implements Exception {
  final int requiredTokens;
  final int windowTokens;
  final List<String> offendingClasses;

  const ContextOverflowError({
    required this.requiredTokens,
    required this.windowTokens,
    required this.offendingClasses,
  });

  @override
  String toString() =>
      'ContextOverflowError: unevictable context (~$requiredTokens tokens '
      'across classes ${offendingClasses.join(', ')}) exceeds the available '
      'window of $windowTokens tokens.';
}

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

  /// Per-region attribution explaining each eviction decision.
  final List<EvictionRecord> evictionRecords;

  /// Per-class admission statistics (empty for class-unaware strategies).
  final Map<String, ContextClassUsage> classUsage;

  const CompiledContext({
    required this.messages,
    required this.totalEstimatedTokens,
    required this.budget,
    this.systemInstruction,
    this.includedRegions = const [],
    this.evictedRegions = const [],
    this.evictionRecords = const [],
    this.classUsage = const {},
  });

  @override
  String toString() =>
      'CompiledContext(messages: ${messages.length}, tokens: ~$totalEstimatedTokens, includedRegions: ${includedRegions.length}, evictedRegions: ${evictedRegions.length})';
}
