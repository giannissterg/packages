import 'package:test/test.dart';
import 'package:vaster_budget/vaster_budget.dart';
import 'package:vaster_scheduler/vaster_scheduler.dart';

void main() {
  group('PriorityTaskQueue', () {
    test('orders tasks by priority, earliest deadline, and creation timestamp', () {
      final queue = PriorityTaskQueue();
      final now = DateTime.now();

      final taskLow = ScheduledTask<String>(
        taskId: 't_low',
        taskName: 'Low Task',
        priority: TaskPriority.low,
        action: () async => 'low',
      );

      final taskHighLater = ScheduledTask<String>(
        taskId: 't_high_later',
        taskName: 'High Later Task',
        priority: TaskPriority.high,
        deadline: now.add(const Duration(hours: 2)),
        action: () async => 'high_later',
      );

      final taskHighSooner = ScheduledTask<String>(
        taskId: 't_high_sooner',
        taskName: 'High Sooner Task',
        priority: TaskPriority.high,
        deadline: now.add(const Duration(minutes: 10)),
        action: () async => 'high_sooner',
      );

      final taskCritical = ScheduledTask<String>(
        taskId: 't_critical',
        taskName: 'Critical Task',
        priority: TaskPriority.critical,
        action: () async => 'critical',
      );

      queue.enqueue(taskLow);
      queue.enqueue(taskHighLater);
      queue.enqueue(taskHighSooner);
      queue.enqueue(taskCritical);

      expect(queue.length, equals(4));

      // 1. Critical priority goes first
      expect(queue.dequeue()?.taskId, equals('t_critical'));
      // 2. High priority with sooner deadline goes next
      expect(queue.dequeue()?.taskId, equals('t_high_sooner'));
      // 3. High priority with later deadline goes next
      expect(queue.dequeue()?.taskId, equals('t_high_later'));
      // 4. Low priority goes last
      expect(queue.dequeue()?.taskId, equals('t_low'));
    });
  });

  group('BasicVasterScheduler', () {
    late BasicVasterScheduler scheduler;

    setUp(() {
      scheduler = BasicVasterScheduler(taskQueue: PriorityTaskQueue());
    });

    test('submits and executes tasks using runAll', () async {
      final executed = <String>[];

      await scheduler.submitTask(
        taskId: 'task_1',
        taskName: 'Task 1',
        priority: TaskPriority.normal,
        action: () async {
          executed.add('task_1');
          return 'ok1';
        },
      );

      await scheduler.submitTask(
        taskId: 'task_2',
        taskName: 'Task 2',
        priority: TaskPriority.high,
        action: () async {
          executed.add('task_2');
          return 'ok2';
        },
      );

      await scheduler.runAll();

      expect(executed, equals(['task_2', 'task_1']));
    });

    test('cancels queued tasks', () async {
      final task = await scheduler.submitTask(
        taskId: 'cancel_me',
        taskName: 'Cancel Task',
        action: () async => 'done',
      );

      // Catch error on task completer to prevent unhandled asynchronous exception
      task.completer.future.catchError((_) => 'cancelled');

      final cancelled = scheduler.cancelTask('cancel_me');
      expect(cancelled, isTrue);
      expect(task.state, equals(ExecutionState.cancelled));

      expect(await scheduler.runNext(), isFalse);
    });

    test('handles budget expiration on task execution', () async {
      final expiredBudget = ExecutionBudget(
        deadline: DateTime.now().subtract(const Duration(seconds: 1)),
      );

      final task = await scheduler.submitTask(
        taskId: 'expired_task',
        taskName: 'Expired Task',
        budget: expiredBudget,
        action: () async => 'should_not_run',
      );

      // Catch error on task completer to prevent unhandled asynchronous exception
      task.completer.future.catchError((_) => 'expired');

      await scheduler.runNext();
      expect(task.state, equals(ExecutionState.timedOut));
    });
  });
}
