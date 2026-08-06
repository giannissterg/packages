
import 'package:vaster_vm/vaster_vm.dart';

import 'package:vaster_replay/vaster_replay.dart';

/// A recorded execution envelope loaded for debugging: the compiled program,
/// the step journal, and the model I/O tape.
class DebugEnvelope {
  final VasterProgram program;
  final VasterExecutionJournal journal;
  final ModelTape tape;

  const DebugEnvelope({
    required this.program,
    required this.journal,
    required this.tape,
  });

  /// Parses an envelope JSON string. Envelopes recorded before the program
  /// was embedded need [programOverride] (from `--program`).
  ///
  /// Envelope parsing itself is the codec's — one owner
  /// (`ReplayEnvelopeCodec`, spec REPLAY_ENVELOPE.md); this factory only
  /// adds the debugger's program-hydration concern.
  factory DebugEnvelope.parse(String json, {VasterProgram? programOverride}) {
    final envelope = const ReplayEnvelopeCodec().decodeString(json);
    final embedded = envelope.programJson == null
        ? null
        : VasterProgram.fromJson(envelope.programJson!);
    final program = programOverride ?? embedded;
    if (program == null) {
      throw StateError(
          'Envelope does not embed its program (recorded before v0.2.0) — '
          'pass the compiled .vbc/.json via --program.');
    }
    return DebugEnvelope(
      program: program,
      journal: envelope.journal,
      tape: envelope.tape,
    );
  }
}

/// Raised when re-execution disagrees with the recorded journal — the
/// recording and the current toolchain no longer produce the same machine.
class ReplayDivergence implements Exception {
  final int stepIndex;
  final String detail;
  const ReplayDivergence({required this.stepIndex, required this.detail});

  @override
  String toString() => 'ReplayDivergence at step $stepIndex: $detail';
}

/// Point-in-time view of the replayed VM's context state.
class ContextStateView {
  final List<ContextRegion> regions;
  final ContextClassTable classTable;
  final CompiledContext? lastCompiled;

  const ContextStateView({
    required this.regions,
    required this.classTable,
    required this.lastCompiled,
  });
}

/// Time-travel debugging session over a recorded envelope.
///
/// Two tiers of state, by design:
///
/// * **Journal tier** (instant, pure): cursor navigation, registers, call
///   stack, instruction, register deltas — read straight from frames.
/// * **Materialized tier** (replay-backed): VFS and context state at the
///   cursor, reconstructed by re-executing the program against the model
///   tape on a fresh in-memory VM, step-for-step verified against the
///   journal (any mismatch raises [ReplayDivergence] naming the exact step).
///
/// Stepping forward extends the materialized machine incrementally; seeking
/// backward re-materializes from step 0 (linear, and cheap: model calls
/// answer from the tape).
///
/// Safety: programs with disk mounts are refused at [load] (replay would
/// write the real filesystem); sandbox execution and HITL yields degrade
/// materialization with explicit warnings — journal-tier views always work.
class DebugSession {
  final DebugEnvelope envelope;

  /// Non-fatal limitations detected at load (sandbox execution, HITL).
  final List<String> warnings;

  int _cursor = 0;

  // Materialization state.
  VasterVirtualMachine? _vm;
  VasterRuntime? _runtime;
  int _materializedStep = -1;

  DebugSession._(this.envelope, this.warnings);

  /// Validates the envelope and constructs a session.
  ///
  /// Throws [StateError] for programs that cannot be safely replayed
  /// (disk mounts).
  static DebugSession load(DebugEnvelope envelope) {
    final warnings = <String>[];
    for (final inst in envelope.program.instructions) {
      if (inst is MountFsOp && inst.diskPath != null) {
        throw StateError(
            'Program mounts host disk path "${inst.diskPath}" — replaying '
            'it would write the real filesystem. Debugging disk-mounted '
            'programs is not supported.');
      }
      if (inst is ExecSandboxOp || inst is RegisterSandboxOp) {
        warnings.add(
            'Program executes sandbox code: sandbox output is not recorded '
            'in the tape, so materialized VFS/context state may diverge '
            'from the original run.');
        break;
      }
    }
    if (envelope.program.instructions
        .any((i) => i is YieldHumanInteractionOp)) {
      warnings.add(
          'Program yields for human interaction: materialized state is '
          'unavailable past the first yield (human answers are not taped); '
          'journal views remain exact.');
    }
    return DebugSession._(envelope, warnings);
  }

  // ── Journal tier ─────────────────────────────────────────────────────────

  VasterExecutionJournal get journal => envelope.journal;
  VasterProgram get program => envelope.program;
  ModelTape get tape => envelope.tape;

  int get cursor => _cursor;
  int get length => journal.length;
  bool get isAtStart => _cursor <= 0;
  bool get isAtEnd => _cursor >= length - 1;

  ExecutionStepFrame get currentFrame => journal.getFrameAt(_cursor)!;

  void seek(int step) => _cursor = step.clamp(0, length - 1);
  void stepForward([int steps = 1]) => seek(_cursor + steps);
  void stepBack([int steps = 1]) => seek(_cursor - steps);

  /// All step indices that executed the instruction at [pc] (loop iterations).
  List<int> stepsAtPc(int pc) => [
        for (final f in journal.frames)
          if (f.pc == pc) f.stepIndex,
      ];

  /// Register changes introduced by the current step.
  RegisterDelta diffFromPrevious() {
    final current = currentFrame;
    final before = _cursor == 0
        ? ExecutionStepFrame(
            stepIndex: -1,
            pc: -1,
            instruction: current.instruction,
            registers: const {},
          )
        : journal.getFrameAt(_cursor - 1)!;
    return RegisterDelta.between(before, current);
  }

  /// Model-tape entries, with usage, for the whole run.
  List<ModelTapeEntry> get tapeEntries => tape.entries;

  /// The program's declared result value at the final frame, if any.
  Object? get declaredResult => program.resultBinding == null
      ? null
      : journal.last?.registers[program.resultBinding];

  // ── Materialized tier ────────────────────────────────────────────────────

  /// Number of tape entries consumed by the materialized machine so far —
  /// correlates the cursor position with "model calls made by now".
  int get materializedModelCalls => _replayModel == null
      ? 0
      : tape.entries.length - _replayModel!.remaining;

  ReplayVasterModel? _replayModel;

  /// Re-executes the recording up to (and including) the cursor's step and
  /// returns the live VM for state inspection. Incremental when moving
  /// forward; restarts from step 0 when the cursor moved backward.
  Future<VasterVirtualMachine> materialize() async {
    if (_vm == null || _materializedStep > _cursor) {
      _replayModel = ReplayVasterModel(tape: tape);
      _vm = await VasterVMEngine.bootstrap(
          config: VMConfig(defaultModel: _replayModel!));
      _runtime = VasterRuntime(
        vm: _vm!,
        policy: ExecutionPolicy.unlimited,
        // Wall-clock deadlines are machine-dependent; reconstruction must
        // never time out where the recording didn't.
        budget: ExecutionBudget.unlimited(),
        scheduler: BasicVasterScheduler(taskQueue: PriorityTaskQueue()),
      );
      // Stepping bypasses executeProgram's load path, so install the
      // program-header class table here — the replayed context machine must
      // link with the same segment table the recording used.
      if (program.contextClasses != null) {
        _vm!.contextManager.installClassTable(
            ContextClassTable.fromJson(program.contextClasses!));
      }
      _materializedStep = -1;
    }

    while (_materializedStep < _cursor) {
      final expected = journal.getFrameAt(_materializedStep + 1);
      if (expected == null) break;

      final state =
          await _runtime!.executeStep(program, stepCount: 1);
      _materializedStep++;

      // Frame-exact verification: the recording and this toolchain must
      // produce the same machine, or the debugger says exactly where not.
      if (state.pc != expected.pc + 1 &&
          state.status == RuntimeStatus.running &&
          !_isControlFlow(expected.instruction)) {
        throw ReplayDivergence(
          stepIndex: _materializedStep,
          detail: 'PC after step is ${state.pc}, recorded instruction was '
              'at ${expected.pc}',
        );
      }
      for (final entry in expected.registers.entries) {
        final replayed = state.registers[entry.key];
        if ('$replayed' != '${entry.value}') {
          throw ReplayDivergence(
            stepIndex: _materializedStep,
            detail: 'register "${entry.key}" recorded '
                '${_truncate('${entry.value}')} but replayed '
                '${_truncate('$replayed')}',
          );
        }
      }

      if (state.status == RuntimeStatus.pausedForHuman) {
        throw StateError(
            'Materialization reached a human-interaction yield at step '
            '$_materializedStep — human answers are not taped. Journal '
            'views remain available.');
      }
    }
    return _vm!;
  }

  /// VFS listing at the cursor (materializes on demand).
  Future<List<FileDescriptor>> listVfs(String path) async {
    final vm = await materialize();
    final nodes = await vm.fileSystemManager
        .resolveFileSystem(path)
        .listDirectory(path, recursive: true);
    return [
      for (final node in nodes)
        if (node is VirtualFile) node.descriptor,
    ];
  }

  /// File content at the cursor (materializes on demand).
  Future<String> readVfs(String path) async {
    final vm = await materialize();
    return vm.fileSystemManager.resolveFileSystem(path).readText(path);
  }

  /// Context heap + segment state at the cursor (materializes on demand).
  Future<ContextStateView> contextState() async {
    final vm = await materialize();
    return ContextStateView(
      regions: vm.contextManager.regions,
      classTable: vm.contextManager.classTable,
      lastCompiled: vm.contextManager.lastCompiled,
    );
  }

  static bool _isControlFlow(VasterInstruction instruction) =>
      instruction is JumpOp ||
      instruction is JumpIfOp ||
      instruction is CallOp ||
      instruction is ReturnSubroutineOp ||
      instruction is DecideOp ||
      instruction is HaltOp;

  static String _truncate(String value, [int max = 80]) =>
      value.length <= max ? value : '${value.substring(0, max)}…';
}
