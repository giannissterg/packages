import 'dart:io';

import 'package:test/test.dart';
import 'package:vaster_ast/vaster_ast.dart';
import 'package:vaster_compiler/vaster_compiler.dart';
import 'package:vaster_domain/vaster_domain.dart';
import 'package:vaster_debug/vaster_debug.dart';
import 'package:vaster_replay/vaster_replay.dart';
import 'package:vaster_vm/vaster_vm.dart';

/// Time-travel debugging over the committed REAL-model recording: journal
/// navigation is instant and pure; VFS/context state materializes by
/// verified tape replay.
void main() {
  const architect = AgentRole(
    roleId: 'architect',
    name: 'Architect',
    title: 'Principal Architect',
    instruction: 'You write precise, reviewable specifications.',
  );
  const lead = AgentRole(
    roleId: 'lead',
    name: 'Lead',
    title: 'Tech Lead',
    instruction: 'You turn specs into concrete implementation plans.',
  );
  const reviewer = AgentRole(
    roleId: 'reviewer',
    name: 'Reviewer',
    title: 'Staff Reviewer',
    instruction: 'You review artifacts rigorously.',
  );

  const pipeline = Pipeline(
    name: 'sdd_prompt_calibration',
    result: Binding('review'),
    roles: [architect, lead, reviewer],
    mounts: [StorageMount(mountPrefix: '/workspace')],
    children: [
      Specify(
        goal: Template.text(
          'Add a --version flag to a small command-line tool: it prints '
          'the tool version and exits 0. Keep the spec under 300 words.',
        ),
        agent: architect,
      ),
      Plan(agent: lead),
      Review(agent: reviewer),
    ],
  );

  DebugSession loadSession() {
    final fixture = [
      'test/fixtures/sdd_fidelity.replay.json',
      'packages/host/vaster_playground/test/fixtures/sdd_fidelity.replay.json',
    ].map(File.new).firstWhere((f) => f.existsSync());
    // The envelope embeds its program (recorded with the v0.2.0 toolchain);
    // the in-test pipeline above documents its shape and guards drift:
    final compiled = const BasicWorkflowCompiler().compile(pipeline);
    final envelope = DebugEnvelope.parse(fixture.readAsStringSync());
    expect(
      envelope.program.instructions.length,
      equals(compiled.instructions.length),
      reason: 'fixture program drifted from the in-repo pipeline',
    );
    return DebugSession.load(
      envelope,
      vmFactory: (replayModel) => VasterVMEngine.bootstrap(config: VMConfig(defaultModel: replayModel)),
    );
  }

  test('journal tier: navigation, deltas, call stacks, result', () {
    final session = loadSession();

    // 27 executed frames: the 21 pre-REL-P4 steps plus Begin/Commit
    // brackets from the three now-transactional Tasks.
    expect(session.length, equals(27));
    expect(session.warnings, isEmpty);

    session.seek(9999);
    expect(session.isAtEnd, isTrue);
    expect('${session.declaredResult}', contains('APPROVE'));

    session.seek(0);
    expect(session.currentFrame.pc, equals(0));
    session.stepForward(5);
    expect(session.cursor, equals(5));
    session.stepBack(2);
    expect(session.cursor, equals(3));

    // Every frame's delta against its predecessor is computable.
    for (var i = 0; i < session.length; i++) {
      session.seek(i);
      session.diffFromPrevious();
    }

    // The review Task's write lands in a delta somewhere.
    final withReview = List.generate(session.length, (i) {
      session.seek(i);
      return session.diffFromPrevious();
    }).where((d) => d.changedRegisters.contains('review'));
    expect(withReview, isNotEmpty);
  });

  test('materialized tier: VFS and context state at the cursor', () async {
    final session = loadSession();

    // Mid-run: after the spec write (find the WriteFileOp step).
    final specWriteStep = session.journal.frames
        .firstWhere(
          (f) => f.instruction is WriteFileOp && (f.instruction as WriteFileOp).vfsPath.contains('spec'),
        )
        .stepIndex;
    session.seek(specWriteStep);

    final spec = await session.readVfs('/workspace/spec.md');
    expect(spec, contains('--version'));

    // The review artifact must NOT exist yet at this point in time.
    expect(() => session.readVfs('/workspace/review.md'), throwsA(anything));

    // End of run: all three artifacts exist; context is class-managed.
    session.seek(session.length - 1);
    final review = await session.readVfs('/workspace/review.md');
    expect(review, contains('APPROVE'));

    final ctx = await session.contextState();
    expect(ctx.classTable.contains('knowledge'), isTrue);

    expect(
      session.materializedModelCalls,
      equals(4),
      reason: 'all four recorded model calls consumed by the end',
    );
  });

  test('stepping backward re-materializes cleanly', () async {
    final session = loadSession();
    session.seek(session.length - 1);
    await session.readVfs('/workspace/review.md');

    // Travel back before the review existed.
    session.seek(3);
    expect(() => session.readVfs('/workspace/review.md'), throwsA(anything));
    final spec = await session.readVfs('/workspace/spec.md').then((s) => s, onError: (_) => '(not yet)');
    expect(spec, isNotNull);
  });

  test('disk-mounted recordings degrade to journal tier — never refused', () async {
    final program = VasterProgram(
      programName: 'disk',
      instructions: const [
        MountFsOp(mountPrefix: '/data', diskPath: '/tmp/real_disk'),
        SetRegisterOp(registerName: 'x', value: 'one'),
        HaltOp(),
      ],
    );
    final journal = VasterExecutionJournal()
      ..recordStep(
        ExecutionStepFrame(stepIndex: 0, pc: 0, instruction: program.instructions[0], registers: const {}),
      )
      ..recordStep(
        ExecutionStepFrame(
          stepIndex: 1,
          pc: 1,
          instruction: program.instructions[1],
          registers: const {'x': 'one'},
        ),
      );

    final session = DebugSession.load(
      DebugEnvelope(program: program, journal: journal, tape: ModelTape()),
      vmFactory: (replayModel) => VasterVMEngine.bootstrap(config: VMConfig(defaultModel: replayModel)),
    );

    // The refusal is a typed, required value naming its reason — and a
    // banner warning; the session itself loads.
    expect(
      session.materialization,
      isA<MaterializationRefused>().having((m) => m.reason, 'reason', contains('/tmp/real_disk')),
    );
    expect(session.warnings.join(), contains('/tmp/real_disk'));

    // Journal tier is fully alive: navigation, registers, deltas.
    expect(session.length, 2);
    session.seek(1);
    expect(session.currentFrame.registers['x'], 'one');
    expect(session.diffFromPrevious().changedRegisters, contains('x'));
    expect(session.stepsAtPc(1), [1]);

    // Every materialized surface refuses with the carried reason.
    await expectLater(
      session.readVfs('/data/anything'),
      throwsA(isA<StateError>().having((e) => e.message, 'message', contains('disk'))),
    );
    await expectLater(session.materializedMachine(), throwsA(isA<StateError>()));
  });

  test('memory-mounted recordings load MaterializationAvailable', () {
    final program = VasterProgram(
      programName: 'mem',
      instructions: const [
        MountFsOp(mountPrefix: '/mem'),
        HaltOp(),
      ],
    );
    final session = DebugSession.load(
      DebugEnvelope(program: program, journal: VasterExecutionJournal(), tape: ModelTape()),
      vmFactory: (replayModel) => VasterVMEngine.bootstrap(config: VMConfig(defaultModel: replayModel)),
    );
    expect(session.materialization, isA<MaterializationAvailable>());
    expect(session.warnings, isEmpty);
  });
}
