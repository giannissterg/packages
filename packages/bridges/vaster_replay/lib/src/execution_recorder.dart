import 'package:vaster_instruction/vaster_instruction.dart';
import 'package:vaster_runtime/vaster_runtime.dart';

import 'execution_step_frame.dart';

/// Records live [VasterRuntime] execution into a [VasterExecutionJournal].
///
/// The recorder attaches to a runtime's [VasterRuntime.stepObserver] and
/// appends one [ExecutionStepFrame] per executed instruction, capturing the
/// program counter, the instruction, and the post-execution register snapshot.
/// The resulting journal can then be driven by a [VasterReplayEngine] for
/// time-travel debugging.
///
/// Composes with other observers (e.g. the execution tracer): [attach] chains
/// any observer already installed, and [detach] restores it.
///
/// ```dart
/// final recorder = VasterExecutionRecorder()..attach(runtime);
/// await runtime.executeProgram(program);
/// recorder.detach();
/// final engine = VasterReplayEngine(journal: recorder.journal);
/// ```
class VasterExecutionRecorder {
  /// The journal frames are appended to.
  final VasterExecutionJournal journal;

  // VFS state is intentionally NOT captured per frame: the step observer is
  // synchronous while every snapshot API is async, and per-step page maps
  // would dwarf the journal. DebugSession reconstructs VFS/context state
  // deterministically by replaying the model tape instead.

  int _stepCounter = 0;
  VasterRuntime? _attached;
  RuntimeStepObserver? _previousObserver;

  /// Single stable closure instance so [attach]/[detach] identity checks hold.
  late final RuntimeStepObserver _observer = _onStep;

  VasterExecutionRecorder({
    VasterExecutionJournal? journal,
  }) : journal = journal ?? VasterExecutionJournal();

  /// Whether the recorder is currently attached to a runtime.
  bool get isAttached => _attached != null;

  /// Number of frames recorded so far.
  int get recordedSteps => _stepCounter;

  /// Attaches to [runtime] and begins recording subsequent instructions.
  ///
  /// Any observer already installed keeps firing (chained after the recorder)
  /// and is restored by [detach]. Re-attaching while already attached to
  /// another runtime detaches from that one first; re-attaching to the same
  /// runtime is a no-op.
  void attach(VasterRuntime runtime) {
    if (identical(_attached, runtime)) return;
    if (_attached != null) detach();
    _attached = runtime;
    _previousObserver = runtime.stepObserver;
    runtime.stepObserver = _observer;
  }

  /// Stops recording and restores the previously installed observer.
  void detach() {
    final runtime = _attached;
    if (runtime != null && identical(runtime.stepObserver, _observer)) {
      runtime.stepObserver = _previousObserver;
    }
    _previousObserver = null;
    _attached = null;
  }

  /// Discards all recorded frames and resets the step counter.
  void reset() {
    _stepCounter = 0;
    journal.clear();
  }

  void _onStep(int pc, VasterInstruction instruction, Map<String, Object?> registers) {
    journal.recordStep(
      ExecutionStepFrame(
        stepIndex: _stepCounter++,
        pc: pc,
        instruction: instruction,
        registers: Map<String, Object?>.of(registers),
        // The live call stack makes frames resumable inside subroutines.
        callStack: _attached?.callStackSnapshot ?? const [],
      ),
    );

    _previousObserver?.call(pc, instruction, registers);
  }
}
