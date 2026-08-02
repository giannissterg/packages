import 'package:vaster_runtime/vaster_runtime.dart';

import 'execution_step_frame.dart';
import 'register_delta.dart';

/// Time-Travel Debugging & Deterministic Execution Replay Engine for Vaster VM.
///
/// Navigates a recorded [VasterExecutionJournal]: rewind execution step-by-step
/// ([stepBack]), fast-forward through cached journal frames ([stepForward]),
/// [seek] to an absolute step, inspect what changed between steps ([diffFromPrevious],
/// [diffBetween]), mutate register values ([mutateRegister]), and resume live
/// execution from any frame ([resume]).
class VasterReplayEngine {
  final VasterExecutionJournal journal;
  int _currentStepIndex;

  VasterReplayEngine({
    VasterExecutionJournal? journal,
    int initialStepIndex = 0,
  })  : journal = journal ?? VasterExecutionJournal(),
        _currentStepIndex = initialStepIndex;

  /// Returns the current zero-based step index in the time-travel journal.
  int get currentStepIndex => _currentStepIndex;

  /// Returns the active [ExecutionStepFrame] at [currentStepIndex], or null if journal is empty.
  ExecutionStepFrame? get currentFrame => journal.getFrameAt(_currentStepIndex);

  /// Whether the cursor is at the first recorded frame.
  bool get isAtStart => _currentStepIndex <= 0;

  /// Whether the cursor is at the last recorded frame.
  bool get isAtEnd => _currentStepIndex >= journal.length - 1;

  /// Rewinds program execution backward by [steps] (default: 1 step).
  ///
  /// Returns the restored [ExecutionStepFrame], or null if the journal is empty.
  ExecutionStepFrame? stepBack({int steps = 1}) {
    if (journal.isEmpty) return null;
    _currentStepIndex = (_currentStepIndex - steps).clamp(0, journal.length - 1);
    return currentFrame;
  }

  /// Fast-forwards program execution forward by [steps] (default: 1 step).
  ///
  /// Returns the fast-forwarded [ExecutionStepFrame], or null if the journal is empty.
  ExecutionStepFrame? stepForward({int steps = 1}) {
    if (journal.isEmpty) return null;
    _currentStepIndex = (_currentStepIndex + steps).clamp(0, journal.length - 1);
    return currentFrame;
  }

  /// Moves the cursor to an absolute [stepIndex] (clamped to journal bounds).
  ///
  /// Returns the frame at the resulting index, or null if the journal is empty.
  ExecutionStepFrame? seek(int stepIndex) {
    if (journal.isEmpty) return null;
    _currentStepIndex = stepIndex.clamp(0, journal.length - 1);
    return currentFrame;
  }

  /// Resets the cursor back to the first recorded frame (index 0).
  void reset() => _currentStepIndex = 0;

  /// Mutates virtual register [regName] to [newValue] at the current time-travel step frame.
  void mutateRegister(String regName, Object? newValue) {
    final frame = currentFrame;
    if (frame == null) return;

    final updatedRegisters = Map<String, Object?>.of(frame.registers);
    updatedRegisters[regName] = newValue;

    journal.updateFrameAt(_currentStepIndex, frame.withRegisters(updatedRegisters));
  }

  /// Computes the register delta between the current frame and the one before it.
  ///
  /// Returns null when there is no previous frame (cursor at index 0 or empty journal).
  RegisterDelta? diffFromPrevious() {
    final current = currentFrame;
    final previous = journal.getFrameAt(_currentStepIndex - 1);
    if (current == null || previous == null) return null;
    return RegisterDelta.between(previous, current);
  }

  /// Computes the register delta between journal frames [fromIndex] and [toIndex].
  ///
  /// Returns null if either index is out of range.
  RegisterDelta? diffBetween(int fromIndex, int toIndex) {
    final before = journal.getFrameAt(fromIndex);
    final after = journal.getFrameAt(toIndex);
    if (before == null || after == null) return null;
    return RegisterDelta.between(before, after);
  }

  /// Restores time-travel register state into a live [VasterRuntime] instance for resumption.
  void applyToRuntime(VasterRuntime runtime) {
    final frame = currentFrame;
    if (frame == null) return;

    for (final entry in frame.registers.entries) {
      runtime.setRegister(entry.key, entry.value);
    }
  }

  /// Resumes live execution from the current time-travel frame using the provided [runtime].
  ///
  /// Applies the current frame's registers onto [runtime], then continues the
  /// runtime's active program from the frame's program counter, preserving the
  /// applied state (it runs with `resetState: false`). Any [mutateRegister]
  /// edits made at the current frame therefore survive the resume — including
  /// when resuming from a frame whose `pc == 0`.
  ///
  /// Throws [StateError] if the journal is empty or the runtime has no active
  /// program.
  Future<RuntimeState> resume(VasterRuntime runtime) async {
    final frame = currentFrame;
    if (frame == null) {
      throw StateError('Cannot resume: the execution journal is empty.');
    }
    final program = runtime.currentProgram;
    if (program == null) {
      throw StateError('Cannot resume: the runtime has no active program.');
    }

    applyToRuntime(runtime);

    return runtime.executeProgram(program, startPc: frame.pc, resetState: false);
  }
}
