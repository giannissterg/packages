/// Exception raised when a resource quota limit is breached.
class QuotaExceededException implements Exception {
  final String resourceType; // 'tokens', 'tool_calls', 'deadline', 'subagent_depth'
  final String message;
  final num currentUsage;
  final num quotaLimit;

  const QuotaExceededException({
    required this.resourceType,
    required this.message,
    required this.currentUsage,
    required this.quotaLimit,
  });

  @override
  String toString() =>
      'QuotaExceededException($resourceType): $message (Used: $currentUsage / Limit: $quotaLimit)';
}
