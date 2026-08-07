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
    required ExecutionBudget budget,
    required Future<T> Function() action,
  });

  /// Executes an opcode action through the scheduler.
  Future<T> scheduleOpcode<T>({
    required String taskName,
    TaskPriority priority = TaskPriority.normal,
    required ExecutionBudget budget,
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

  /// Number of tasks this scheduler dispatches concurrently — the machine's
  /// virtual core count. With one core, dispatch is strictly serial. More
  /// cores let CPU-cheap, I/O-heavy tasks (model calls dominate this VM's
  /// latency) overlap on the event loop while the priority queue still
  /// decides dispatch order.
  final int cores;

  /// Tasks currently being executed, across all cores.
  final Set<ScheduledTask<dynamic>> _running = {};

  BasicVasterScheduler({required this.taskQueue, this.cores = 1}) : assert(cores >= 1, 'cores must be >= 1');

  /// Unmodifiable snapshot of the tasks currently in flight.
  List<ScheduledTask<dynamic>> get runningTasks => List.unmodifiable(_running);

  /// The single in-flight task when running serially; with multiple cores,
  /// an arbitrary in-flight task (kept for backward compatibility — prefer
  /// [runningTasks]).
  ScheduledTask<dynamic>? get currentRunningTask => _running.isEmpty ? null : _running.first;

  @override
  Future<ScheduledTask<T>> submitTask<T>({
    required String taskId,
    required String taskName,
    TaskPriority priority = TaskPriority.normal,
    DateTime? deadline,
    required ExecutionBudget budget,
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
    required ExecutionBudget budget,
    required Future<T> Function() action,
  }) async {
    if (budget.isExpired) {
      throw TimeoutException('Execution budget or deadline expired before executing opcode $taskName');
    }
    return action();
  }

  @override
  Future<bool> runNext() async {
    final task = taskQueue.dequeue();
    if (task == null) return false;

    _running.add(task);
    task.state = ExecutionState.running;

    if (task.budget.isExpired) {
      task.state = ExecutionState.timedOut;
      task.completer.completeError(TimeoutException('Execution budget expired for task ${task.taskId}'));
      _running.remove(task);
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
      _running.remove(task);
    }

    return true;
  }

  @override
  Future<void> runAll() async {
    // A pool of [cores] workers drains the queue cooperatively. Each worker
    // pulls the next task in priority order; while one worker's task awaits
    // I/O, the event loop runs the others. A worker that finds the queue
    // empty may not exit while tasks are still in flight — a running task
    // (e.g. a job quantum) can enqueue follow-up work — so it sleeps until
    // any in-flight task settles, then re-checks.
    Future<void> worker() async {
      while (true) {
        final dispatched = await runNext();
        if (dispatched) continue;
        final inFlight = _running.toList();
        if (inFlight.isEmpty) return;
        await Future.any(inFlight.map((t) => t.completer.future)).then<void>((_) {}, onError: (Object _) {});
      }
    }

    await Future.wait([for (var i = 0; i < cores; i++) worker()]);
  }

  @override
  bool pauseTask(String taskId) {
    for (final task in _running) {
      if (task.taskId == taskId) {
        task.state = ExecutionState.paused;
        return true;
      }
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
