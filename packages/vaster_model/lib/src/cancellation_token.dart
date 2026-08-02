/// Lightweight token handle to signal and observe cancellation requests across asynchronous operations.
class CancellationToken {
  bool _isCancelled = false;
  String? _reason;

  /// Whether cancellation has been requested.
  bool get isCancelled => _isCancelled;

  /// Cancellation reason if cancelled.
  String? get reason => _reason;

  /// Requests cancellation with an optional reason.
  void cancel([String? reason]) {
    _isCancelled = true;
    _reason = reason;
  }

  /// Throws a [StateError] if cancellation has been requested.
  void throwIfCancelled() {
    if (_isCancelled) {
      throw StateError(_reason != null
          ? 'Operation cancelled: $_reason'
          : 'Operation was cancelled.');
    }
  }

  @override
  String toString() =>
      'CancellationToken(isCancelled: $_isCancelled, reason: $_reason)';
}
