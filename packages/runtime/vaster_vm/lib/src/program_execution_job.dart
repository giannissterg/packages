import 'package:vaster_budget/vaster_budget.dart';
import 'package:vaster_instruction/vaster_instruction.dart';
import 'package:vaster_runtime/vaster_runtime.dart';
import 'package:vaster_scheduler/vaster_scheduler.dart';

/// Tracked execution handle for a program submitted to [VasterVirtualMachine].
class ProgramExecutionJob {
  /// Unique identifier of this program execution job.
  final String jobId;

  /// The ISA program being executed.
  final VasterProgram program;

  /// The runtime engine instance for this job.
  final VasterRuntime runtime;

  /// Scoped execution budget allocated for this job.
  final ExecutionBudget budget;

  /// Task priority.
  final TaskPriority priority;

  /// Current execution state snapshot.
  RuntimeState lastState;

  ProgramExecutionJob({
    required this.jobId,
    required this.program,
    required this.runtime,
    required this.budget,
    this.priority = TaskPriority.normal,
    required this.lastState,
  });

  bool get isDone =>
      lastState.status == RuntimeStatus.halted ||
      lastState.status == RuntimeStatus.error ||
      lastState.status == RuntimeStatus.timedOut;

  bool get isPausedForHuman => lastState.status == RuntimeStatus.pausedForHuman;
}
