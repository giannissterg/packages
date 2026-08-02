import 'dart:convert';

import 'package:test/test.dart';
import 'package:vaster_budget/vaster_budget.dart';
import 'package:vaster_instruction/vaster_instruction.dart';
import 'package:vaster_model_fake/vaster_model_fake.dart';
import 'package:vaster_policy/vaster_policy.dart';
import 'package:vaster_replay/vaster_replay.dart';
import 'package:vaster_runtime/vaster_runtime.dart';
import 'package:vaster_scheduler/vaster_scheduler.dart';
import 'package:vaster_vm/vaster_vm.dart';

void main() {
  group('Journal navigation (vaster_replay)', () {
    late VasterExecutionJournal journal;
    late VasterReplayEngine replayEngine;

    setUp(() {
      journal = VasterExecutionJournal();

      journal.recordStep(ExecutionStepFrame(
        stepIndex: 0,
        pc: 0,
        instruction: const PromptOp(promptText: 'Initial Prompt', outputVar: 'r0'),
        registers: {'r0': 'Initial Prompt'},
        vfsSnapshot: CowFileSnapshot.empty(),
      ));

      journal.recordStep(ExecutionStepFrame(
        stepIndex: 1,
        pc: 1,
        instruction: const DispatchAgentTaskOp(
          agentId: 'a1',
          taskPrompt: 'Write Code',
          outputVar: 'r1',
        ),
        registers: {'r0': 'Initial Prompt', 'r1': 'Generated Code v1'},
        vfsSnapshot: CowFileSnapshot.empty(),
      ));

      journal.recordStep(ExecutionStepFrame(
        stepIndex: 2,
        pc: 2,
        instruction: const HaltOp(),
        registers: {
          'r0': 'Initial Prompt',
          'r1': 'Generated Code v1',
          '__output__': 'Final Report',
        },
        vfsSnapshot: CowFileSnapshot.empty(),
      ));

      replayEngine = VasterReplayEngine(journal: journal, initialStepIndex: 2);
    });

    test('stepBack rewinds execution steps', () {
      expect(replayEngine.currentStepIndex, equals(2));
      expect(replayEngine.currentFrame?.pc, equals(2));
      expect(replayEngine.isAtEnd, isTrue);

      final prevFrame = replayEngine.stepBack();
      expect(prevFrame, isNotNull);
      expect(replayEngine.currentStepIndex, equals(1));
      expect(replayEngine.currentFrame?.registers['r1'], equals('Generated Code v1'));

      replayEngine.stepBack();
      expect(replayEngine.currentStepIndex, equals(0));
      expect(replayEngine.currentFrame?.pc, equals(0));
      expect(replayEngine.isAtStart, isTrue);
    });

    test('stepBack clamps at the first frame', () {
      replayEngine.stepBack(steps: 99);
      expect(replayEngine.currentStepIndex, equals(0));
    });

    test('stepForward fast-forwards execution steps', () {
      replayEngine.stepBack(steps: 2);
      expect(replayEngine.currentStepIndex, equals(0));

      final fwdFrame = replayEngine.stepForward();
      expect(fwdFrame, isNotNull);
      expect(replayEngine.currentStepIndex, equals(1));
      expect(replayEngine.currentFrame?.pc, equals(1));
    });

    test('seek and reset move the cursor to an absolute step', () {
      expect(replayEngine.seek(1)?.pc, equals(1));
      expect(replayEngine.currentStepIndex, equals(1));

      // Out-of-range seeks clamp.
      expect(replayEngine.seek(99)?.pc, equals(2));

      replayEngine.reset();
      expect(replayEngine.currentStepIndex, equals(0));
    });

    test('mutateRegister modifies frame register contents', () {
      replayEngine.stepBack(steps: 1); // step index 1
      expect(replayEngine.currentFrame?.registers['r1'], equals('Generated Code v1'));

      replayEngine.mutateRegister('r1', 'Mutated Code v2 (Patched)');
      expect(replayEngine.currentFrame?.registers['r1'], equals('Mutated Code v2 (Patched)'));
      // The mutation is persisted in the journal, not just the local view.
      expect(journal.getFrameAt(1)?.registers['r1'], equals('Mutated Code v2 (Patched)'));
    });
  });

  group('Register diffing', () {
    late VasterReplayEngine engine;

    setUp(() {
      final journal = VasterExecutionJournal()
        ..recordStep(ExecutionStepFrame(
          stepIndex: 0,
          pc: 0,
          instruction: const PromptOp(promptText: 'p', outputVar: 'r0'),
          registers: {'r0': 'a'},
          vfsSnapshot: CowFileSnapshot.empty(),
        ))
        ..recordStep(ExecutionStepFrame(
          stepIndex: 1,
          pc: 1,
          instruction: const SetRegisterOp(registerName: 'r1', value: 'b'),
          registers: {'r0': 'a', 'r1': 'b'},
          vfsSnapshot: CowFileSnapshot.empty(),
        ))
        ..recordStep(ExecutionStepFrame(
          stepIndex: 2,
          pc: 2,
          instruction: const SetRegisterOp(registerName: 'r0', value: 'z'),
          registers: {'r0': 'z', 'r1': 'b'},
          vfsSnapshot: CowFileSnapshot.empty(),
        ));
      engine = VasterReplayEngine(journal: journal, initialStepIndex: 2);
    });

    test('diffFromPrevious reports a modified register', () {
      final delta = engine.diffFromPrevious();
      expect(delta, isNotNull);
      expect(delta!.changedRegisters, equals(['r0']));
      expect(delta.changes.single.kind, equals(RegisterChangeKind.modified));
      expect(delta.changes.single.previousValue, equals('a'));
      expect(delta.changes.single.newValue, equals('z'));
    });

    test('diffFromPrevious is null at the first frame', () {
      engine.reset();
      expect(engine.diffFromPrevious(), isNull);
    });

    test('diffBetween reports an added register across steps', () {
      final delta = engine.diffBetween(0, 1);
      expect(delta!.changes.single.kind, equals(RegisterChangeKind.added));
      expect(delta.changes.single.register, equals('r1'));
      expect(delta.changes.single.newValue, equals('b'));
    });
  });

  group('JSON serialization round-trip', () {
    test('frame survives toJson/fromJson', () {
      final frame = ExecutionStepFrame(
        stepIndex: 3,
        pc: 7,
        instruction: const DispatchAgentTaskOp(
          agentId: 'a1',
          taskPrompt: 'Write Code',
          outputVar: 'r1',
        ),
        registers: {'r0': 'hello', 'count': 42},
        vfsSnapshot: CowFileSnapshot.empty(),
      );

      final restored =
          ExecutionStepFrame.fromJson(jsonDecode(jsonEncode(frame.toJson())));

      expect(restored.stepIndex, equals(3));
      expect(restored.pc, equals(7));
      expect(restored.instruction, isA<DispatchAgentTaskOp>());
      expect((restored.instruction as DispatchAgentTaskOp).agentId, equals('a1'));
      expect(restored.registers, equals({'r0': 'hello', 'count': 42}));
    });

    test('journal survives toJson/fromJson', () {
      final journal = VasterExecutionJournal()
        ..recordStep(ExecutionStepFrame(
          stepIndex: 0,
          pc: 0,
          instruction: const SetRegisterOp(registerName: 'x', value: 1),
          registers: {'x': 1},
          vfsSnapshot: CowFileSnapshot.empty(),
        ))
        ..recordStep(ExecutionStepFrame(
          stepIndex: 1,
          pc: 1,
          instruction: const HaltOp(),
          registers: {'x': 1},
          vfsSnapshot: CowFileSnapshot.empty(),
        ));

      final restored =
          VasterExecutionJournal.fromJson(jsonDecode(jsonEncode(journal.toJson())));

      expect(restored.length, equals(2));
      expect(restored.last?.instruction, isA<HaltOp>());
    });
  });

  group('Live recording + resume (end-to-end)', () {
    late VasterVirtualMachine vm;
    late VasterRuntime runtime;

    setUp(() async {
      vm = await VasterVMEngine.bootstrap(
        config: VMConfig(defaultModel: FakeVasterModel()),
      );
      runtime = VasterRuntime(
        vm: vm,
        policy: ExecutionPolicy.unlimited,
        budget: ExecutionBudget.unlimited(),
        scheduler: BasicVasterScheduler(taskQueue: PriorityTaskQueue()),
      );
    });

    tearDown(() async {
      await vm.shutdown();
    });

    test('recorder captures a frame per executed instruction', () async {
      const program = VasterProgram(
        programName: 'recorder_demo',
        instructions: [
          SetRegisterOp(registerName: 'greeting', value: 'hello'),
          SetRegisterOp(registerName: 'target', value: 'world'),
          ConcatRegisterOp(
            targetVar: '__output__',
            sourceVars: ['greeting', 'target'],
          ),
          HaltOp(),
        ],
      );

      final recorder = VasterExecutionRecorder()..attach(runtime);
      final finalState = await runtime.executeProgram(program);
      recorder.detach();

      expect(finalState.status, equals(RuntimeStatus.halted));
      expect(recorder.journal.length, equals(4));

      // Frame pcs mirror the program counter of each executed instruction.
      expect(recorder.journal.frames.map((f) => f.pc), equals([0, 1, 2, 3]));

      // Register state accumulates across recorded frames.
      expect(recorder.journal.getFrameAt(0)?.registers['greeting'], equals('hello'));
      expect(recorder.journal.getFrameAt(1)?.registers['target'], equals('world'));

      // Time-travel diff pinpoints the register introduced at step 1.
      final engine = VasterReplayEngine(
        journal: recorder.journal,
        initialStepIndex: 1,
      );
      final delta = engine.diffFromPrevious();
      expect(delta!.changedRegisters, equals(['target']));
      expect(delta.changes.single.kind, equals(RegisterChangeKind.added));

      // After detaching, further execution is not recorded.
      expect(runtime.stepObserver, isNull);
    });

    test('resume re-runs the program from a mid-execution frame', () async {
      const program = VasterProgram(
        programName: 'resume_demo',
        instructions: [
          SetRegisterOp(registerName: 'a', value: 'one'),
          SetRegisterOp(registerName: 'b', value: 'two'),
          HaltOp(),
        ],
      );

      final recorder = VasterExecutionRecorder()..attach(runtime);
      await runtime.executeProgram(program);
      recorder.detach();

      // Rewind to the frame at pc 1 and patch a register, then resume forward.
      final engine = VasterReplayEngine(journal: recorder.journal)..seek(1);
      engine.mutateRegister('b', 'patched');

      final resumed = await engine.resume(runtime);
      expect(resumed.status, equals(RuntimeStatus.halted));
      // pc 1 (re-executed) overwrites b back to 'two', proving execution resumed
      // from the frame's pc rather than merely restoring the snapshot.
      expect(resumed.registers['b'], equals('two'));
      expect(resumed.registers['a'], equals('one'));
    });

    test('resume from a pc-0 frame preserves applied registers (no silent reset)', () async {
      const program = VasterProgram(
        programName: 'reset_footgun',
        instructions: [
          SetRegisterOp(registerName: 'a', value: 'one'),
          HaltOp(),
        ],
      );

      final recorder = VasterExecutionRecorder()..attach(runtime);
      await runtime.executeProgram(program);
      recorder.detach();

      // Seek to the very first frame (pc 0) and inject a register the program
      // itself never sets, then resume.
      final engine = VasterReplayEngine(journal: recorder.journal)..seek(0);
      engine.mutateRegister('injected', 'survives');

      final resumed = await engine.resume(runtime);
      expect(resumed.status, equals(RuntimeStatus.halted));
      // The injected register survives a resume from pc 0. The old
      // `startPc == 0` reset heuristic would have silently wiped it.
      expect(resumed.registers['injected'], equals('survives'));
      expect(resumed.registers['a'], equals('one'));
    });

    test('resume throws when the runtime has no active program', () {
      final engine = VasterReplayEngine()
        ..journal.recordStep(ExecutionStepFrame(
          stepIndex: 0,
          pc: 0,
          instruction: const HaltOp(),
          registers: const {},
          vfsSnapshot: CowFileSnapshot.empty(),
        ));
      expect(() => engine.resume(runtime), throwsStateError);
    });
  });
}
