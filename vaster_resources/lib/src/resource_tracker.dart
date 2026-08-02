import 'quota_exceeded_exception.dart';
import 'resource_quota.dart';

/// Active resource usage tracker enforcing a [ResourceQuota].
class ResourceTracker {
  final ResourceQuota quota;
  final Stopwatch _stopwatch = Stopwatch();

  int _consumedTokens = 0;
  int _toolCallCount = 0;

  ResourceTracker({required this.quota}) {
    _stopwatch.start();
  }

  /// Total consumed tokens so far.
  int get consumedTokens => _consumedTokens;

  /// Total tool call executions so far.
  int get toolCallCount => _toolCallCount;

  /// Elapsed execution time.
  Duration get elapsedTime => _stopwatch.elapsed;

  /// Consumes [count] tokens and checks quota limit.
  void consumeTokens(int count) {
    _consumedTokens += count;
    if (quota.maxTokenBudget != null && _consumedTokens > quota.maxTokenBudget!) {
      throw QuotaExceededException(
        resourceType: 'tokens',
        message: 'Token budget exceeded.',
        currentUsage: _consumedTokens,
        quotaLimit: quota.maxTokenBudget!,
      );
    }
  }

  /// Increments tool call count by [count] and checks quota limit.
  void recordToolCall({int count = 1}) {
    _toolCallCount += count;
    if (quota.maxToolCallsPerTask != null && _toolCallCount > quota.maxToolCallsPerTask!) {
      throw QuotaExceededException(
        resourceType: 'tool_calls',
        message: 'Max tool call limit per task exceeded.',
        currentUsage: _toolCallCount,
        quotaLimit: quota.maxToolCallsPerTask!,
      );
    }
  }

  /// Checks if time deadline has expired.
  void checkDeadline() {
    if (quota.timeDeadline != null && _stopwatch.elapsed > quota.timeDeadline!) {
      throw QuotaExceededException(
        resourceType: 'deadline',
        message: 'Execution deadline expired.',
        currentUsage: _stopwatch.elapsed.inMilliseconds,
        quotaLimit: quota.timeDeadline!.inMilliseconds,
      );
    }
  }
}
