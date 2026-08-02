import 'scheduled_task.dart';

/// Deadline-aware priority queue for ordering tasks.
///
/// Ordering rules:
/// 1. Higher [TaskPriority] comes first (critical > high > normal > low).
/// 2. Earlier [deadline] comes first (imminent deadline tie-breaking).
/// 3. Earliest [createdAt] timestamp (FIFO).
class PriorityTaskQueue {
  final List<ScheduledTask<dynamic>> _queue = [];

  bool get isEmpty => _queue.isEmpty;
  bool get isNotEmpty => _queue.isNotEmpty;
  int get length => _queue.length;

  /// Enqueues a task and maintains priority-deadline ordering.
  void enqueue(ScheduledTask<dynamic> task) {
    _queue.add(task);
    _sort();
  }

  /// Removes and returns the highest priority next task, or null if queue is empty.
  ScheduledTask<dynamic>? dequeue() {
    if (_queue.isEmpty) return null;
    return _queue.removeAt(0);
  }

  /// Views the highest priority next task without removing it.
  ScheduledTask<dynamic>? peek() {
    if (_queue.isEmpty) return null;
    return _queue.first;
  }

  /// Removes a task by [taskId].
  ScheduledTask<dynamic>? remove(String taskId) {
    final idx = _queue.indexWhere((t) => t.taskId == taskId);
    if (idx != -1) return _queue.removeAt(idx);
    return null;
  }

  /// Clears all queued tasks.
  void clear() => _queue.clear();

  /// Returns an unmodifiable snapshot of the queued tasks.
  List<ScheduledTask<dynamic>> toList() => List.unmodifiable(_queue);

  void _sort() {
    _queue.sort((a, b) {
      // 1. Priority comparison (higher priority first)
      final prioComp = b.priority.value.compareTo(a.priority.value);
      if (prioComp != 0) return prioComp;

      // 2. Deadline comparison (earlier deadline first)
      if (a.deadline != null && b.deadline != null) {
        final dlComp = a.deadline!.compareTo(b.deadline!);
        if (dlComp != 0) return dlComp;
      } else if (a.deadline != null) {
        return -1; // a has deadline, b does not -> a comes first
      } else if (b.deadline != null) {
        return 1; // b has deadline, a does not -> b comes first
      }

      // 3. Creation timestamp (FIFO)
      return a.createdAt.compareTo(b.createdAt);
    });
  }
}
