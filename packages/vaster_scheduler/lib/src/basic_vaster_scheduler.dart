import 'dart:async';
import 'package:vaster_budget/vaster_budget.dart';
import 'execution_state.dart';
import 'priority_task_queue.dart';
import 'scheduled_task.dart';
import 'task_priority.dart';

/// Contract for task scheduling, priority queues, and execution orchestration.
abstract interface class VasterScheduler {
  PriorityTaskQueue get taskQueue;

  /// Submits a task to the scheduler queue.
  Future<ScheduledTask<T>> submitTask<T>({
    required String taskId,
    required String taskName,
    TaskPriority priority = TaskPriority.normal,
    DateTime? deadline,
    ExecutionBudget? budget,
    required Future<T> Function() action,
  });

  /// Executes an opcode action through the scheduler.
  Future<T> scheduleOpcode<T>({
    required String taskName,
    TaskPriority priority = TaskPriority.normal,
    ExecutionBudget? budget,
    required Future<T> Function() action,
  });

  /// Processes the next highest priority task in the queue.
  Future<bool> runNext();

  /// Processes all tasks in the queue until empty.
  Future<void> runAll();

  /// Pauses a queued or running task by ID.
  bool pauseTask(String taskId);

  /// Cancels a queued task by ID.
  bool cancelTask(String taskId);
}

/// Standard implementation of [VasterScheduler] requiring a [PriorityTaskQueue] (Rule 5).
class BasicVasterScheduler implements VasterScheduler {
  @override
  final PriorityTaskQueue taskQueue;

  ScheduledTask<dynamic>? _currentRunningTask;

  BasicVasterScheduler({required this.taskQueue});

  ScheduledTask<dynamic>? get currentRunningTask => _currentRunningTask;

  @override
  Future<ScheduledTask<T>> submitTask<T>({
    required String taskId,
    required String taskName,
    TaskPriority priority = TaskPriority.normal,
    DateTime? deadline,
    ExecutionBudget? budget,
    required Future<T> Function() action,
  }) async {
    final task = ScheduledTask<T>(
      taskId: taskId,
      taskName: taskName,
      priority: priority,
      deadline: deadline,
      budget: budget,
      action: action,
      state: ExecutionState.queued,
    );
    taskQueue.enqueue(task);
    return task;
  }

  @override
  Future<T> scheduleOpcode<T>({
    required String taskName,
    TaskPriority priority = TaskPriority.normal,
    ExecutionBudget? budget,
    required Future<T> Function() action,
  }) async {
    final effectiveBudget = budget ?? ExecutionBudget.unlimited();
    if (effectiveBudget.isExpired) {
      throw TimeoutException('Execution budget or deadline expired before executing opcode $taskName');
    }
    return action();
  }

  @override
  Future<bool> runNext() async {
    final task = taskQueue.dequeue();
    if (task == null) return false;

    _currentRunningTask = task;
    task.state = ExecutionState.running;

    if (task.budget.isExpired) {
      task.state = ExecutionState.timedOut;
      task.completer.completeError(TimeoutException('Execution budget expired for task ${task.taskId}'));
      _currentRunningTask = null;
      return true;
    }

    try {
      final result = await task.action();
      task.state = ExecutionState.completed;
      task.completer.complete(result);
    } catch (e, st) {
      task.state = ExecutionState.failed;
      task.completer.completeError(e, st);
    } finally {
      _currentRunningTask = null;
    }

    return true;
  }

  @override
  Future<void> runAll() async {
    while (await runNext()) {}
  }

  @override
  bool pauseTask(String taskId) {
    if (_currentRunningTask?.taskId == taskId) {
      _currentRunningTask!.state = ExecutionState.paused;
      return true;
    }
    final task = taskQueue.remove(taskId);
    if (task != null) {
      task.state = ExecutionState.paused;
      return true;
    }
    return false;
  }

  @override
  bool cancelTask(String taskId) {
    final task = taskQueue.remove(taskId);
    if (task != null) {
      task.state = ExecutionState.cancelled;
      task.completer.completeError(StateError('Task $taskId was cancelled by scheduler'));
      return true;
    }
    return false;
  }
}
