/// An operation observed a cancellation request. Cancellation is a
/// caller's decision, not an error — it gets a real type so downstream
/// classification (sealed `TaskOutcome`, retry policies) never has to
/// match message prefixes. Implements [StateError]'s shape loosely via
/// [message] for readability, but catch THIS type.
final class CancelledException implements Exception {
  final String message;
  const CancelledException(this.message);
  @override
  String toString() => 'CancelledException: $message';
}

/// Lightweight token handle to signal and observe cancellation requests across asynchronous operations.
class CancellationToken {
  bool _isCancelled = false;
  String? _reason;

  /// Whether cancellation has been requested.
  bool get isCancelled => _isCancelled;

  /// Cancellation reason if cancelled.
  String? get reason => _reason;

  /// Requests cancellation with an optional reason; returns true when
  /// THIS call performed the transition, false when already cancelled
  /// (the first cause wins and repeat cancels are observable no-ops).
  bool cancel([String? reason]) {
    if (_isCancelled) return false;
    _isCancelled = true;
    _reason = reason;
    return true;
  }

  /// Throws a [CancelledException] if cancellation has been requested.
  void throwIfCancelled() {
    if (_isCancelled) {
      throw CancelledException(
        _reason != null ? 'Operation cancelled: $_reason' : 'Operation was cancelled.',
      );
    }
  }

  @override
  String toString() => 'CancellationToken(isCancelled: $_isCancelled, reason: $_reason)';
}
