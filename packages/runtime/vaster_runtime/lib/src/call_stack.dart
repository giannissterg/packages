import 'package:vaster_machine_state/vaster_machine_state.dart';

/// A single subroutine activation record pushed onto the [CallStack].
class ActivationRecord {
  /// Name of the called function (for debugging / disassembly).
  final String functionName;

  /// The PC address to return to after the subroutine completes.
  final int returnPc;

  /// Optional register name to write the subroutine's return value into.
  final String? outputVar;

  const ActivationRecord({
    required this.functionName,
    required this.returnPc,
    this.outputVar,
  });

  Map<String, dynamic> toJson() => {
        'functionName': functionName,
        'returnPc': returnPc,
        if (outputVar != null) 'outputVar': outputVar,
      };

  factory ActivationRecord.fromJson(Map<String, dynamic> json) =>
      ActivationRecord(
        functionName: json['functionName'] as String? ?? '',
        returnPc: (json['returnPc'] as num).toInt(),
        outputVar: json['outputVar'] as String?,
      );

  @override
  String toString() =>
      'ActivationRecord(fn: "$functionName", returnPc: $returnPc, out: $outputVar)';
}

/// The VM's subroutine call stack.
///
/// Tracks activation records for `CallOp` / `ReturnSubroutineOp` so that
/// [VasterRuntime] can delegate all stack frame management here rather than
/// maintaining a raw `List<Map<String,dynamic>>` inline.
class CallStack implements MachineStateComponent {
  final List<ActivationRecord> _frames = [];

  /// Whether there are no active frames.
  bool get isEmpty => _frames.isEmpty;

  /// Number of currently active frames.
  int get depth => _frames.length;

  /// Pushes a new [ActivationRecord] for a subroutine call and returns
  /// the new stack depth (Rule 11).
  int push(ActivationRecord frame) {
    _frames.add(frame);
    return _frames.length;
  }

  /// Pops and returns the most recent activation record.
  ///
  /// Throws [StateError] if the stack is empty.
  ActivationRecord pop() {
    if (_frames.isEmpty) {
      throw StateError('CallStack underflow: attempted to pop an empty stack.');
    }
    return _frames.removeLast();
  }

  /// Immutable snapshot of the active frames, outermost first — the machine
  /// word for continuation capture.
  List<ActivationRecord> snapshot() => List.unmodifiable(_frames);

  /// Replaces the active frames with [frames] (outermost first), restoring a
  /// previously captured snapshot.
  void restore(Iterable<ActivationRecord> frames) {
    _frames
      ..clear()
      ..addAll(frames);
  }

  /// Clears all frames (e.g. on program start).
  void clear() => _frames.clear();

  @override
  String get stateKey => 'callStack';

  @override
  Map<String, dynamic> captureState() =>
      {'frames': [for (final f in _frames) f.toJson()]};

  @override
  void restoreState(Map<String, dynamic> snapshot) => restore([
        for (final f in snapshot['frames'] as List? ?? const [])
          ActivationRecord.fromJson(Map<String, dynamic>.from(f as Map)),
      ]);
}
