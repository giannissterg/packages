import 'dart:async';

/// FIFO mailbox serializing one agent's tasks — agents are actors.
///
/// A [VasterAgent] owns a single session transcript; two tasks executing
/// concurrently on it interleave their model turns into one history, which is
/// unspecified behavior every provider rejects in spirit. The mailbox makes
/// the actor rule structural: tasks for the same agent run one at a time in
/// acceptance order, while tasks for *different* agents still overlap freely.
///
/// Failures don't poison the queue: a task that throws rejects its own
/// future, and the next queued task still runs.
final class AgentMailbox {
  Future<void> _tail = Future<void>.value();
  int _pending = 0;

  /// Tasks accepted and not yet completed (including the one running).
  int get pendingTasks => _pending;

  /// Enqueues [action] behind everything already accepted and returns its
  /// own future.
  Future<T> enqueue<T>(Future<T> Function() action) {
    _pending++;
    final run = _tail.then((_) async {
      try {
        return await action();
      } finally {
        _pending--;
      }
    });
    _tail = run.then((_) {}, onError: (_) {});
    return run;
  }
}
