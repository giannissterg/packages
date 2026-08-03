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

  @override
  String toString() =>
      'ActivationRecord(fn: "$functionName", returnPc: $returnPc, out: $outputVar)';
}

/// The VM's subroutine call stack.
///
/// Tracks activation records for `CallOp` / `ReturnSubroutineOp` so that
/// [VasterRuntime] can delegate all stack frame management here rather than
/// maintaining a raw `List<Map<String,dynamic>>` inline.
class CallStack {
  final List<ActivationRecord> _frames = [];

  /// Whether there are no active frames.
  bool get isEmpty => _frames.isEmpty;

  /// Number of currently active frames.
  int get depth => _frames.length;

  /// Pushes a new [ActivationRecord] for a subroutine call.
  void push(ActivationRecord frame) => _frames.add(frame);

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
}
