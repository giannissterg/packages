import 'dart:convert';

import 'package:test/test.dart';
import 'package:vaster_checkpoint/vaster_checkpoint.dart';
import 'package:vaster_debug/vaster_debug.dart';
import 'package:vaster_model_fake/vaster_model_fake.dart';
import 'package:vaster_replay/vaster_replay.dart';
import 'package:vaster_vm/vaster_vm.dart';

/// TT-P4: the debugger is a surgery table, not just a microscope.
///
/// A recorded run is re-entered mid-flight: the machine state after step N
/// is reconstructed by verified tape replay, captured as a
/// `MachineCheckpoint`, and restored into a FRESH VM whose default model is
/// a live backend. The prefix answers from the tape (never re-paid); the
/// suffix executes live — on a different model than the recording, which is
/// the whole point of fixing a bad decision mid-run.
void main() {
  /// Two model turns bracketing a VFS write: resume between them and the
  /// second turn — and only the second — must reach the live model.
  VasterProgram buildProgram() => VasterProgram(
    programName: 'tt_resume_probe',
    resultBinding: 'verdict',
    instructions: const [
      CreateSessionOp(sessionId: 'sess'), // pc 0
      SetSessionOp(sessionId: 'sess'), // pc 1
      PromptOp(promptText: 'phase one: gather the notes', outputVar: 'notes'), // pc 2
      WriteFileOp(vfsPath: '/mem/notes.txt', content: 'notes written'), // pc 3
      PromptOp(promptText: 'phase two: deliver the verdict', outputVar: 'verdict'), // pc 4
      HaltOp(), // pc 5
    ],
  );

  Future<(VasterVMEngine, VasterRuntime)> boot(VasterModel model) async {
    final vm = await VasterVMEngine.bootstrap(config: VMConfig(defaultModel: model));
    final runtime = VasterRuntime(
      vm: vm,
      policy: ExecutionPolicy.unlimited,
      budget: ExecutionBudget.unlimited(),
      scheduler: BasicVasterScheduler(taskQueue: PriorityTaskQueue()),
    );
    return (vm, runtime);
  }

  /// Records the program on fake model ALPHA and returns the envelope JSON —
  /// the exact artifact `vaster run --record` writes.
  Future<String> recordEnvelope(VasterProgram program) async {
    final tape = ModelTape();
    final alpha = FakeVasterModel(
      modelName: 'alpha-recorded',
      responseMap: const {'phase one': 'ALPHA-NOTES', 'phase two': 'ALPHA-VERDICT'},
    );
    final (vm, runtime) = await boot(RecordingVasterModel(inner: alpha, tape: tape));
    final recorder = VasterExecutionRecorder()..attach(runtime);
    final state = await runtime.executeProgram(program);
    recorder.detach();
    await vm.shutdown();
    expect(state.status, RuntimeStatus.halted, reason: 'error: ${state.errorDetails}');
    expect(tape.entries, hasLength(2));
    return jsonEncode(
      const ReplayEnvelopeCodec().encode(
        programJson: program.toJson(),
        journalJson: recorder.journal.toJson(),
        tape: tape,
      ),
    );
  }

  test('resume live from mid-recording: prefix taped, suffix on a NEW model', () async {
    final program = buildProgram();
    final envelopeJson = await recordEnvelope(program);

    // ── Debug the recording; park the cursor after the VFS write (pc 3),
    //    i.e. after phase one but before the verdict turn. ──
    final session = DebugSession.load(
      DebugEnvelope.parse(envelopeJson),
      vmFactory: (replayModel) => VasterVMEngine.bootstrap(config: VMConfig(defaultModel: replayModel)),
    );
    final writeStep = session.journal.frames.firstWhere((f) => f.instruction is WriteFileOp).stepIndex;
    session.seek(writeStep);

    final machine = await session.materializedMachine();
    final checkpoint = MachineCheckpoint.capture(
      runtime: machine.runtime,
      vm: machine.host,
      program: session.program,
    );
    expect(session.materializedModelCalls, 1, reason: 'exactly phase one consumed from the tape');
    expect(checkpoint.budgetConsumedTokens, greaterThan(0), reason: 'the prefix meters ride the checkpoint');

    // ── Kill every live object; resume from JSON alone in a fresh VM whose
    //    default model is a DIFFERENT live backend. ──
    final restored = MachineCheckpoint.fromJson(
      jsonDecode(jsonEncode(checkpoint.toJson())) as Map<String, dynamic>,
    );
    final bravo = FakeVasterModel(
      modelName: 'bravo-live',
      responseMap: const {'phase one': 'NEVER-ASKED', 'phase two': 'BRAVO-VERDICT'},
    );
    final vmB = await VasterVMEngine.bootstrap(config: VMConfig(defaultModel: bravo));
    addTearDown(vmB.shutdown);
    final runtimeB = await restored.restoreRuntime(
      vm: vmB,
      policy: ExecutionPolicy.unlimited,
      scheduler: BasicVasterScheduler(taskQueue: PriorityTaskQueue()),
    );
    final finalState = await restored.resumeWith(runtimeB);

    expect(finalState.status, RuntimeStatus.halted, reason: 'error: ${finalState.errorDetails}');

    // The suffix ran live: the verdict is BRAVO's, and BRAVO only ever saw
    // phase two — the prefix was never re-paid.
    expect('${finalState.registers['verdict']}', contains('BRAVO-VERDICT'));
    expect(bravo.recordedRequests, hasLength(1));
    expect(bravo.recordedRequests.single.messages.last.text, contains('phase two'));

    // The prefix state crossed intact: ALPHA's register value and the file.
    expect('${finalState.registers['notes']}', contains('ALPHA-NOTES'));
    expect(
      await vmB.fileSystemManager.resolveFileSystem('/mem/notes.txt').readText('/mem/notes.txt'),
      'notes written',
    );

    // Meters continued — the live suffix charged on top of the taped prefix.
    expect(runtimeB.budget.consumedTokens, greaterThan(restored.budgetConsumedTokens));
  });

  test('the debug session survives being captured: inspection still works after', () async {
    final program = buildProgram();
    final session = DebugSession.load(
      DebugEnvelope.parse(await recordEnvelope(program)),
      vmFactory: (replayModel) => VasterVMEngine.bootstrap(config: VMConfig(defaultModel: replayModel)),
    );
    session.seek(session.length - 1);
    await session.materializedMachine();

    // Capture is a read: the cursor, materialization, and views stay valid.
    expect('${session.declaredResult}', contains('ALPHA-VERDICT'));
    expect(await session.readVfs('/mem/notes.txt'), 'notes written');
    expect(session.materializedModelCalls, 2);
  });
}
