/// Tracks resource capacity (time, tokens, monetary cost) and supports
/// hierarchical child budgets bounded by parent remaining capacity.
class ExecutionBudget {
  final Duration? maxDuration;
  final DateTime? deadline;
  final int? maxTokens;
  final double? maxCost;

  Duration _consumedDuration;
  int _consumedTokens;
  double _consumedCost;

  ExecutionBudget({
    this.maxDuration,
    this.deadline,
    this.maxTokens,
    this.maxCost,
    Duration initialConsumedDuration = Duration.zero,
    int initialConsumedTokens = 0,
    double initialConsumedCost = 0.0,
  })  : _consumedDuration = initialConsumedDuration,
        _consumedTokens = initialConsumedTokens,
        _consumedCost = initialConsumedCost;

  /// Creates an unconstrained / unlimited budget.
  factory ExecutionBudget.unlimited() => ExecutionBudget();

  Duration get consumedDuration => _consumedDuration;
  int get consumedTokens => _consumedTokens;
  double get consumedCost => _consumedCost;

  /// Returns remaining time duration if [maxDuration] is set, or null if unconstrained.
  Duration? get remainingDuration {
    if (maxDuration == null) return null;
    final remaining = maxDuration! - _consumedDuration;
    return remaining.isNegative ? Duration.zero : remaining;
  }

  /// Returns remaining tokens if [maxTokens] is set, or null if unconstrained.
  int? get remainingTokens {
    if (maxTokens == null) return null;
    final remaining = maxTokens! - _consumedTokens;
    return remaining < 0 ? 0 : remaining;
  }

  /// Returns remaining cost if [maxCost] is set, or null if unconstrained.
  double? get remainingCost {
    if (maxCost == null) return null;
    final remaining = maxCost! - _consumedCost;
    return remaining < 0 ? 0.0 : remaining;
  }

  /// Checks if the budget is expired (either by maxDuration, deadline, maxTokens, or maxCost).
  bool get isExpired {
    if (deadline != null && DateTime.now().isAfter(deadline!)) return true;
    if (maxDuration != null && _consumedDuration >= maxDuration!) return true;
    if (maxTokens != null && _consumedTokens >= maxTokens!) return true;
    if (maxCost != null && _consumedCost >= maxCost!) return true;
    return false;
  }

  /// Deducts elapsed time from the budget.
  void consumeTime(Duration elapsed) {
    _consumedDuration += elapsed;
  }

  /// Deducts tokens from the budget.
  void consumeTokens(int tokens) {
    _consumedTokens += tokens;
  }

  /// Deducts cost from the budget.
  void consumeCost(double cost) {
    _consumedCost += cost;
  }

  /// Creates a child budget bounded strictly by this parent's remaining capacity.
  ExecutionBudget createChildBudget({
    Duration? maxDuration,
    DateTime? deadline,
    int? maxTokens,
    double? maxCost,
  }) {
    // 1. Bound maxDuration by parent remainingDuration
    Duration? childMaxDuration = maxDuration;
    final parentRemDuration = remainingDuration;
    if (parentRemDuration != null) {
      if (childMaxDuration == null || childMaxDuration > parentRemDuration) {
        childMaxDuration = parentRemDuration;
      }
    }

    // 2. Bound deadline by parent deadline
    DateTime? childDeadline = deadline;
    if (this.deadline != null) {
      if (childDeadline == null || childDeadline.isAfter(this.deadline!)) {
        childDeadline = this.deadline;
      }
    }

    // 3. Bound maxTokens by parent remainingTokens
    int? childMaxTokens = maxTokens;
    final parentRemTokens = remainingTokens;
    if (parentRemTokens != null) {
      if (childMaxTokens == null || childMaxTokens > parentRemTokens) {
        childMaxTokens = parentRemTokens;
      }
    }

    // 4. Bound maxCost by parent remainingCost
    double? childMaxCost = maxCost;
    final parentRemCost = remainingCost;
    if (parentRemCost != null) {
      if (childMaxCost == null || childMaxCost > parentRemCost) {
        childMaxCost = parentRemCost;
      }
    }

    return ExecutionBudget(
      maxDuration: childMaxDuration,
      deadline: childDeadline,
      maxTokens: childMaxTokens,
      maxCost: childMaxCost,
    );
  }
}
