import 'package:vaster_filesystem/vaster_filesystem.dart';
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
/// ```dart
/// final recorder = VasterExecutionRecorder()..attach(runtime);
/// await runtime.executeProgram(program);
/// recorder.detach();
/// final engine = VasterReplayEngine(journal: recorder.journal);
/// ```
class VasterExecutionRecorder {
  /// The journal frames are appended to.
  final VasterExecutionJournal journal;

  /// Optional provider capturing a Copy-on-Write VFS snapshot per step.
  ///
  /// When null, each frame records an empty snapshot ([CowFileSnapshot.empty]).
  /// Supply this to correlate register state with virtual filesystem state at
  /// each step (e.g. bridging the active filesystem manager's transaction).
  final CowFileSnapshot Function()? vfsSnapshotProvider;

  int _stepCounter = 0;
  VasterRuntime? _attached;

  /// Single stable closure instance so [attach]/[detach] identity checks hold.
  late final RuntimeStepObserver _observer = _onStep;

  VasterExecutionRecorder({
    VasterExecutionJournal? journal,
    this.vfsSnapshotProvider,
  }) : journal = journal ?? VasterExecutionJournal();

  /// Whether the recorder is currently attached to a runtime.
  bool get isAttached => _attached != null;

  /// Number of frames recorded so far.
  int get recordedSteps => _stepCounter;

  /// Attaches to [runtime] and begins recording subsequent instructions.
  ///
  /// Replaces any existing step observer on [runtime]. Detaching from a prior
  /// runtime first is the caller's responsibility if that matters.
  void attach(VasterRuntime runtime) {
    _attached = runtime;
    runtime.stepObserver = _observer;
  }

  /// Stops recording and clears the observer from the attached runtime.
  void detach() {
    final runtime = _attached;
    if (runtime != null && identical(runtime.stepObserver, _observer)) {
      runtime.stepObserver = null;
    }
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
        vfsSnapshot: vfsSnapshotProvider?.call() ?? CowFileSnapshot.empty(),
      ),
    );
  }
}
