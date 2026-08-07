import 'package:vaster_instruction/vaster_instruction.dart';
import 'package:vaster_model/vaster_model.dart';
import 'package:vaster_runtime/vaster_runtime.dart';

/// Immutable point-in-time snapshot frame captured at a specific ISA instruction execution step.
class ExecutionStepFrame {
  /// Sequential zero-based step index in the execution journal.
  final int stepIndex;

  /// Program counter offset at this step.
  final int pc;

  /// The ISA instruction opcode executed at this step.
  final VasterInstruction instruction;

  /// Snapshot of virtual register file contents (`Map<String, Object?>`).
  final Map<String, Object?> registers;

  /// Subroutine activation records live at this step (outermost first).
  /// Required for resuming into a frame recorded inside a subroutine — a
  /// machine paused in a call is defined by where it will return to.
  /// VFS state is deliberately NOT recorded per frame: it is reconstructed
  /// deterministically by replaying the tape (see DebugSession).
  final List<ActivationRecord> callStack;

  /// Model response payload emitted during this step (if an LLM call occurred).
  final ModelResponse? modelOutput;

  /// Timestamp when this step frame was captured.
  final DateTime timestamp;

  ExecutionStepFrame({
    required this.stepIndex,
    required this.pc,
    required this.instruction,
    required this.registers,
    this.callStack = const [],
    this.modelOutput,
    DateTime? timestamp,
  }) : timestamp = timestamp ?? DateTime.now();

  /// Creates a shallow modified copy of this frame with updated registers.
  ExecutionStepFrame withRegisters(Map<String, Object?> newRegisters) {
    return ExecutionStepFrame(
      stepIndex: stepIndex,
      pc: pc,
      instruction: instruction,
      registers: Map.of(newRegisters),
      callStack: callStack,
      modelOutput: modelOutput,
      timestamp: timestamp,
    );
  }

  /// Serializes this step frame to a durable JSON map.
  Map<String, dynamic> toJson() => {
        'stepIndex': stepIndex,
        'pc': pc,
        'instruction': instruction.toJson(),
        'registers': registers,
        if (callStack.isNotEmpty)
          'callStack': [
            for (final f in callStack)
              {
                'functionName': f.functionName,
                'returnPc': f.returnPc,
                if (f.outputVar != null) 'outputVar': f.outputVar,
              },
          ],
        if (modelOutput != null) 'modelOutput': modelOutput!.toJson(),
        'timestamp': timestamp.toIso8601String(),
      };

  /// Reconstructs a step frame from its [toJson] representation.
  factory ExecutionStepFrame.fromJson(Map<String, dynamic> json) {
    final rawModel = json['modelOutput'];
    return ExecutionStepFrame(
      stepIndex: json['stepIndex'] as int,
      pc: json['pc'] as int,
      instruction: VasterInstruction.fromJson(
        Map<String, dynamic>.from(json['instruction'] as Map),
      ),
      registers: Map<String, Object?>.from(
        (json['registers'] as Map?) ?? const {},
      ),
      // Tolerant of legacy frames (which carried a vfsSnapshot instead).
      callStack: [
        for (final raw in (json['callStack'] as List? ?? const []))
          ActivationRecord(
            functionName:
                (raw as Map)['functionName'] as String? ?? '',
            returnPc: raw['returnPc'] as int? ?? 0,
            outputVar: raw['outputVar'] as String?,
          ),
      ],
      modelOutput: rawModel == null
          ? null
          : ModelResponse.fromJson(Map<String, dynamic>.from(rawModel as Map)),
      timestamp: DateTime.tryParse(json['timestamp'] as String? ?? ''),
    );
  }
}

/// In-memory execution journal recording a linear sequence of [ExecutionStepFrame] instances.
class VasterExecutionJournal {
  final List<ExecutionStepFrame> _frames = [];

  /// Creates an empty execution journal.
  VasterExecutionJournal();

  /// Total number of recorded execution step frames.
  int get length => _frames.length;

  /// Whether the journal has no recorded frames.
  bool get isEmpty => _frames.isEmpty;

  /// Whether the journal has at least one recorded frame.
  bool get isNotEmpty => _frames.isNotEmpty;

  /// The first recorded frame, or null if the journal is empty.
  ExecutionStepFrame? get first => _frames.isEmpty ? null : _frames.first;

  /// The most recently recorded frame, or null if the journal is empty.
  ExecutionStepFrame? get last => _frames.isEmpty ? null : _frames.last;

  /// Returns unmodifiable list of all step frames.
  List<ExecutionStepFrame> get frames => List.unmodifiable(_frames);

  /// Appends a new [ExecutionStepFrame] to the journal.
  /// Appends [frame] and returns its zero-based step index — the handle
  /// [getFrameAt] and seek operations address it by (Rule 11).
  int recordStep(ExecutionStepFrame frame) {
    _frames.add(frame);
    return _frames.length - 1;
  }

  /// Retrieves the step frame at zero-based [stepIndex], or null if out of range.
  ExecutionStepFrame? getFrameAt(int stepIndex) {
    if (stepIndex < 0 || stepIndex >= _frames.length) return null;
    return _frames[stepIndex];
  }

  /// Finds the latest step frame matching program counter [pc].
  ExecutionStepFrame? getLatestFrameAtPc(int pc) {
    for (var i = _frames.length - 1; i >= 0; i--) {
      if (_frames[i].pc == pc) return _frames[i];
    }
    return null;
  }

  /// Replaces frame at [stepIndex] with updated [newFrame].
  void updateFrameAt(int stepIndex, ExecutionStepFrame newFrame) {
    if (stepIndex >= 0 && stepIndex < _frames.length) {
      _frames[stepIndex] = newFrame;
    }
  }

  /// Finds every step frame recorded at program counter [pc], in order.
  List<ExecutionStepFrame> framesAtPc(int pc) =>
      _frames.where((f) => f.pc == pc).toList(growable: false);

  /// Clears all recorded step frames; returns how many were dropped.
  int clear() {
    final dropped = _frames.length;
    _frames.clear();
    return dropped;
  }

  /// Serializes the entire journal to a durable JSON map.
  Map<String, dynamic> toJson() => {
        'frames': _frames.map((f) => f.toJson()).toList(),
      };

  /// Reconstructs a journal from its [toJson] representation.
  factory VasterExecutionJournal.fromJson(Map<String, dynamic> json) {
    final journal = VasterExecutionJournal();
    for (final raw in (json['frames'] as List?) ?? const []) {
      journal.recordStep(
        ExecutionStepFrame.fromJson(Map<String, dynamic>.from(raw as Map)),
      );
    }
    return journal;
  }
}
