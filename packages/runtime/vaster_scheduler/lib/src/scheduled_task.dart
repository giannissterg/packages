import 'dart:async';

import 'package:vaster_budget/vaster_budget.dart';

import 'execution_state.dart';
import 'task_priority.dart';

/// Single schedulable task unit with priority, deadline, budget, and execution callback.
class ScheduledTask<T> {
  final String taskId;
  final String taskName;
  final TaskPriority priority;
  final DateTime? deadline;
  final ExecutionBudget budget;
  final Future<T> Function() action;
  final DateTime createdAt;
  final Completer<T> completer = Completer<T>();

  ExecutionState state;

  ScheduledTask({
    required this.taskId,
    required this.taskName,
    this.priority = TaskPriority.normal,
    this.deadline,
    ExecutionBudget? budget,
    required this.action,
    DateTime? createdAt,
    this.state = ExecutionState.created,
  }) : budget = budget ?? ExecutionBudget.unlimited(),
       createdAt = createdAt ?? DateTime.now();
}
