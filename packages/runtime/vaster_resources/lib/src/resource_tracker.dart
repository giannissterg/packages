import 'quota_exceeded_exception.dart';
import 'resource_quota.dart';

/// Active resource usage tracker enforcing a [ResourceQuota].
class ResourceTracker {
  ResourceQuota _quota;
  final Stopwatch _stopwatch = Stopwatch();

  int _consumedTokens = 0;
  int _toolCallCount = 0;
  double _consumedCost = 0.0;

  ResourceTracker({required this._quota}) {
    _stopwatch.start();
  }

  /// The quota currently being enforced.
  ResourceQuota get quota => _quota;

  /// Total consumed tokens so far.
  int get consumedTokens => _consumedTokens;

  /// Total tool call executions so far.
  int get toolCallCount => _toolCallCount;

  /// Total consumed monetary cost so far.
  double get consumedCost => _consumedCost;

  /// Elapsed execution time.
  Duration get elapsedTime => _stopwatch.elapsed;

  /// Replaces the enforced quota and restarts measurement: all counters
  /// reset to zero and the deadline clock restarts. Used when a program
  /// scope declares a new quota (e.g. a `SetQuotaOp` in bytecode).
  /// Returns the quota it displaced (Rule 11).
  ResourceQuota applyQuota(ResourceQuota quota) {
    final displaced = _quota;
    _quota = quota;
    _consumedTokens = 0;
    _toolCallCount = 0;
    _consumedCost = 0.0;
    _stopwatch
      ..reset()
      ..start();
    return displaced;
  }

  /// Consumes [count] tokens and checks quota limit.
  /// Returns the new consumed-token total (the running balance); throws
  /// [QuotaExceededException] when the quota trips.
  int consumeTokens(int count) {
    _consumedTokens += count;
    if (_quota.maxTokenBudget != null && _consumedTokens > _quota.maxTokenBudget!) {
      throw QuotaExceededException(
        resourceType: 'tokens',
        message: 'Token budget exceeded.',
        currentUsage: _consumedTokens,
        quotaLimit: _quota.maxTokenBudget!,
      );
    }
    return _consumedTokens;
  }

  /// Restores previously consumed meters (checkpoint resume). Sets raw
  /// counters WITHOUT quota checks: the values were legal when captured, and
  /// a resume must not re-trip a quota the original run already survived —
  /// the next real consumption enforces as usual.
  /// Returns the restored consumption snapshot (echo — the caller can
  /// assert what the tracker now believes).
  ({int tokens, double cost, int toolCalls}) restoreConsumed({
    required int tokens,
    required double cost,
    required int toolCalls,
  }) {
    _consumedTokens = tokens;
    _consumedCost = cost;
    _toolCallCount = toolCalls;
    return (tokens: _consumedTokens, cost: _consumedCost, toolCalls: _toolCallCount);
  }

  /// Returns the new tool-call total; throws when the quota trips.
  int recordToolCall({int count = 1}) {
    _toolCallCount += count;
    if (_quota.maxToolCallsPerTask != null && _toolCallCount > _quota.maxToolCallsPerTask!) {
      throw QuotaExceededException(
        resourceType: 'tool_calls',
        message: 'Max tool call limit per task exceeded.',
        currentUsage: _toolCallCount,
        quotaLimit: _quota.maxToolCallsPerTask!,
      );
    }
    return _toolCallCount;
  }

  /// Consumes [cost] monetary units and checks quota limit.
  /// Returns the new consumed-cost total; throws when the quota trips.
  double consumeCost(double cost) {
    _consumedCost += cost;
    if (_quota.maxCostBudget != null && _consumedCost > _quota.maxCostBudget!) {
      throw QuotaExceededException(
        resourceType: 'cost',
        message: 'Cost budget exceeded.',
        currentUsage: _consumedCost,
        quotaLimit: _quota.maxCostBudget!,
      );
    }
    return _consumedCost;
  }

  /// Checks if time deadline has expired.
  /// Returns the time REMAINING before the deadline (null when no
  /// deadline is declared); throws when it has already passed.
  Duration? checkDeadline() {
    if (_quota.timeDeadline != null && _stopwatch.elapsed > _quota.timeDeadline!) {
      throw QuotaExceededException(
        resourceType: 'deadline',
        message: 'Execution deadline expired.',
        currentUsage: _stopwatch.elapsed.inMilliseconds,
        quotaLimit: _quota.timeDeadline!.inMilliseconds,
      );
    }
    final deadline = _quota.timeDeadline;
    return deadline == null ? null : deadline - _stopwatch.elapsed;
  }
}
