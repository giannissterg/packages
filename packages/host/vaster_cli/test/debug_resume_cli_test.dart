import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:vaster_cli/vaster_cli.dart';
import 'package:vaster_model_fake/vaster_model_fake.dart';
import 'package:vaster_replay/vaster_replay.dart';
import 'package:vaster_vm/vaster_vm.dart';

/// TT-P4 through the real CLI verb: `vaster debug <envelope> --resume-at N`
/// reconstructs the state after step N by verified replay and finishes the
/// run on the live backend; the REPL's `checkpoint` verb exports a durable
/// checkpoint any `vaster resume` can pick up.
void main() {
  late Directory tmp;
  late VasterCliRunner runner;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('vaster_ttp4_');
    runner = VasterCliRunner();
  });

  tearDown(() => tmp.deleteSync(recursive: true));

  VasterProgram probeProgram() => VasterProgram(
        programName: 'ttp4_probe',
        resultBinding: 'verdict',
        instructions: const [
          CreateSessionOp(sessionId: 'sess'),
          SetSessionOp(sessionId: 'sess'),
          PromptOp(promptText: 'phase one: gather the notes', outputVar: 'notes'),
          WriteFileOp(vfsPath: '/mem/notes.txt', content: 'notes written'),
          PromptOp(promptText: 'phase two: deliver the verdict', outputVar: 'verdict'),
          HaltOp(),
        ],
      );

  /// Records the probe on a fake model and writes the envelope file.
  Future<String> writeEnvelope(VasterProgram program) async {
    final tape = ModelTape();
    final vm = await VasterVMEngine.bootstrap(
      config: VMConfig(
        defaultModel: RecordingVasterModel(
          inner: FakeVasterModel(
            responseMap: const {'phase one': 'ALPHA-NOTES', 'phase two': 'ALPHA-VERDICT'},
          ),
          tape: tape,
        ),
      ),
    );
    final runtime = VasterRuntime(
      vm: vm,
      policy: ExecutionPolicy.unlimited,
      budget: ExecutionBudget.unlimited(),
      scheduler: BasicVasterScheduler(taskQueue: PriorityTaskQueue()),
    );
    final recorder = VasterExecutionRecorder()..attach(runtime);
    final state = await runtime.executeProgram(program);
    recorder.detach();
    await vm.shutdown();
    expect(state.status, RuntimeStatus.halted, reason: 'error: ${state.errorDetails}');

    final path = '${tmp.path}/probe.replay.json';
    File(path).writeAsStringSync(
      jsonEncode(
        const ReplayEnvelopeCodec().encode(
          programJson: program.toJson(),
          journalJson: recorder.journal.toJson(),
          tape: tape,
        ),
      ),
    );
    return path;
  }

  test('--resume-at finishes the run live on the fake backend', () async {
    final envelopePath = await writeEnvelope(probeProgram());

    // Step 3 is the WriteFileOp — resume with phase two live.
    final out = StringBuffer();
    final code = await runner.run(
      ['debug', envelopePath, '--resume-at', '3', '--backend', 'fake'],
      stdoutSink: out,
      stderrSink: out,
    );

    expect(code, 0, reason: out.toString());
    final text = out.toString();
    expect(text, contains('LIVE RESUME (TT-P4)'));
    expect(text, contains('1 taped model call(s)'), reason: 'only phase one rode the prefix');
    expect(text, contains('LIVE RESUME COMPLETE'));
    expect(text, contains('status : halted'));
    // The verdict came from the LIVE fake backend, not the tape.
    expect(text, isNot(contains('ALPHA-VERDICT')));
  });

  test('--resume-at rejects an out-of-range step', () async {
    final envelopePath = await writeEnvelope(probeProgram());
    final out = StringBuffer();
    final code = await runner.run(
      ['debug', envelopePath, '--resume-at', '99', '--backend', 'fake'],
      stdoutSink: out,
      stderrSink: out,
    );
    expect(code, 1);
    expect(out.toString(), contains('must be a step in 0..'));
  });

  test('disk-mounted recordings open journal-tier; materialization refuses cleanly', () async {
    // Synthesized recording of a disk-mounted program — the shape every
    // external-codebase planning run produces.
    final program = VasterProgram(
      programName: 'disk_probe',
      instructions: const [
        MountFsOp(mountPrefix: '/project', diskPath: '/tmp/some_repo'),
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
    final envelopePath = '${tmp.path}/disk.replay.json';
    File(envelopePath).writeAsStringSync(
      jsonEncode(
        const ReplayEnvelopeCodec().encode(
          programJson: program.toJson(),
          journalJson: journal.toJson(),
          tape: ModelTape(),
        ),
      ),
    );

    // Journal tier works: the session opens with the warning, regs read.
    final regsOut = StringBuffer();
    final regsCode = await runner.run(
      ['debug', envelopePath, '--script', 'seek 1; regs'],
      stdoutSink: regsOut,
      stderrSink: regsOut,
    );
    expect(regsCode, 0, reason: regsOut.toString());
    expect(regsOut.toString(), contains('/tmp/some_repo'), reason: 'the load warning names the mount');
    expect(regsOut.toString(), contains('x = one'));

    // A materialized view refuses with the reason — the REPL survives.
    final vfsOut = StringBuffer();
    final vfsCode = await runner.run(
      ['debug', envelopePath, '--script', 'vfs /project'],
      stdoutSink: vfsOut,
      stderrSink: vfsOut,
    );
    expect(vfsCode, 0);
    expect(vfsOut.toString(), contains('✗'));
    expect(vfsOut.toString(), contains('disk'));

    // Live resume needs materialization: refused with exit 1.
    final resumeOut = StringBuffer();
    final resumeCode = await runner.run(
      ['debug', envelopePath, '--resume-at', '1', '--backend', 'fake'],
      stdoutSink: resumeOut,
      stderrSink: resumeOut,
    );
    expect(resumeCode, 1);
    expect(resumeOut.toString(), contains('disk'));
  });

  test('the checkpoint REPL verb exports a file vaster resume completes', () async {
    final envelopePath = await writeEnvelope(probeProgram());
    final ckptPath = '${tmp.path}/at_step3.ckpt.json';

    final debugOut = StringBuffer();
    final debugCode = await runner.run(
      ['debug', envelopePath, '--script', 'seek 3; checkpoint $ckptPath'],
      stdoutSink: debugOut,
      stderrSink: debugOut,
    );
    expect(debugCode, 0, reason: debugOut.toString());
    expect(File(ckptPath).existsSync(), isTrue);

    final resumeOut = StringBuffer();
    final resumeCode = await runner.run(
      ['resume', ckptPath, '--backend', 'fake'],
      stdoutSink: resumeOut,
      stderrSink: resumeOut,
    );
    expect(resumeCode, 0, reason: resumeOut.toString());
    expect(resumeOut.toString(), contains('RESUME COMPLETE'));
  });
}
