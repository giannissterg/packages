import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:vaster_cli/vaster_cli.dart';
import 'package:vaster_instruction/vaster_instruction.dart';
import 'package:vaster_replay/vaster_replay.dart';

void main() {
  late VasterCliRunner runner;

  setUp(() {
    runner = VasterCliRunner();
  });

  test('vaster --help prints usage output', () async {
    final buffer = StringBuffer();
    final exitCode = await runner.run(['--help'], stdoutSink: buffer);

    expect(exitCode, equals(0));
    expect(buffer.toString(), contains('VASTER LLM VIRTUAL MACHINE — OFFICIAL CLI'));
    expect(buffer.toString(), contains('disassemble'));
    expect(buffer.toString(), contains('doctor'));
    expect(buffer.toString(), contains('inspect'));
    expect(buffer.toString(), contains('run'));
    expect(buffer.toString(), contains('serve'));
  });

  test('vaster doctor runs health diagnostics', () async {
    final buffer = StringBuffer();
    final exitCode = await runner.run(['doctor'], stdoutSink: buffer);

    expect(exitCode, equals(0));
    expect(buffer.toString(), contains('VASTER VM SYSTEM DIAGNOSTICS & DOCTOR'));
    expect(buffer.toString(), contains('Dart SDK Version'));
  });

  test('vaster debug drives a scripted time-travel session', () async {
    final fixture = File(
        '../vaster_playground/test/fixtures/sdd_fidelity.replay.json');
    if (!fixture.existsSync()) {
      // Workspace-root invocation.
      expect(
          File('packages/vaster_playground/test/fixtures/sdd_fidelity.replay.json')
              .existsSync(),
          isTrue);
    }
    final envelopePath = fixture.existsSync()
        ? fixture.path
        : 'packages/vaster_playground/test/fixtures/sdd_fidelity.replay.json';

    final buffer = StringBuffer();
    final exitCode = await runner.run([
      'debug',
      envelopePath,
      '--script',
      'info; tape; seek 8; diff; l; seek 20; result; q',
    ], stdoutSink: buffer);

    final output = buffer.toString();
    expect(exitCode, equals(0));
    expect(output, contains('VASTER TIME-TRAVEL DEBUGGER'));
    expect(output, contains('result  : review'));
    // Tape view shows real recorded usage and wire cost.
    expect(output, contains(r'$0.3812'));
    // The dispatch step's delta shows the spec binding being written.
    expect(output, contains('spec'));
    // Listing renders through the shared disassembler with a cursor.
    expect(output, contains('→'));
    // The declared result at the final step is the recorded review.
    expect(output, contains('APPROVE'));
  });

  test('record-then-debug round trip on a fresh offline run', () async {
    final tmp = Directory.systemTemp.createTempSync('vaster_debug_e2e_');
    addTearDown(() => tmp.deleteSync(recursive: true));

    // A small program: write, read, prompt, result.
    final program = VasterProgram(
      programName: 'debug_e2e',
      resultBinding: 'answer',
      instructions: const [
        MountFsOp(mountPrefix: '/mem'),
        WriteFileOp(vfsPath: '/mem/q.txt', content: 'what is up?'),
        ReadFileOp(vfsPath: '/mem/q.txt', outputVar: 'q'),
        PromptOp(promptText: r'Answer: ${q}', outputVar: 'answer'),
        HaltOp(),
      ],
    );
    final programPath = '${tmp.path}/prog.vbc';
    File(programPath).writeAsBytesSync(program.toBytes());
    final envelopePath = '${tmp.path}/run.replay.json';

    // 1. Record a fake-backend run.
    final runOut = StringBuffer();
    final runExit = await runner.run(
        ['run', programPath, '--record', envelopePath],
        stdoutSink: runOut);
    expect(runExit, equals(0));
    expect(File(envelopePath).existsSync(), isTrue);

    // 2. Time-travel the recording we just made.
    final dbgOut = StringBuffer();
    final dbgErr = StringBuffer();
    final dbgExit = await runner.run([
      'debug',
      envelopePath,
      '--script',
      'seek 1; cat /mem/q.txt; b 1; cat /mem/q.txt; seek 4; result; q',
    ], stdoutSink: dbgOut, stderrSink: dbgErr);

    final output = dbgOut.toString();
    expect(dbgExit, equals(0));
    // At step 1 the file exists; stepping BACK before the write, it doesn't.
    expect(output, contains('what is up?'));
    expect(dbgErr.toString(), contains('File not found'));
    // The declared result at the end carries the fake model's answer.
    expect(output, contains('Answer:'));
  });

  test('vaster unknown command returns exit code 1', () async {
    final errBuffer = StringBuffer();
    final exitCode = await runner.run(['unknown_cmd'], stderrSink: errBuffer);

    expect(exitCode, equals(1));
    expect(errBuffer.toString(), contains('Unknown Vaster command "unknown_cmd"'));
  });

  group('vaster compile', () {
    late Directory tempDir;

    const program = VasterProgram(programName: 'cli_compile', instructions: [
      SetRegisterOp(registerName: 'greeting', value: 'hello'),
      ConcatRegisterOp(targetVar: '__output__', sourceVars: ['greeting']),
      HaltOp(),
    ]);

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('vaster_cli_compile_');
      File('${tempDir.path}/prog.json')
          .writeAsStringSync(jsonEncode(program.toJson()));
    });

    tearDown(() async {
      if (await tempDir.exists()) await tempDir.delete(recursive: true);
    });

    test('emits a decodable .vbc artifact from program JSON', () async {
      final out = StringBuffer();
      final exitCode = await runner.run(
        ['compile', '${tempDir.path}/prog.json'],
        stdoutSink: out,
      );

      expect(exitCode, equals(0));
      expect(out.toString(), contains('Compiled cli_compile'));

      final artifact = File('${tempDir.path}/prog.vbc');
      expect(artifact.existsSync(), isTrue);
      final decoded = VasterProgramBinary.fromBytes(artifact.readAsBytesSync());
      expect(decoded.programName, equals('cli_compile'));
      expect(decoded.instructions, hasLength(3));
    });

    test('--check analyzes without writing an artifact', () async {
      final out = StringBuffer();
      final exitCode = await runner.run(
        ['compile', '--check', '${tempDir.path}/prog.json'],
        stdoutSink: out,
      );

      expect(exitCode, equals(0));
      expect(out.toString(), contains('OK: cli_compile'));
      expect(File('${tempDir.path}/prog.vbc').existsSync(), isFalse);
    });

    test('refuses to overwrite the input artifact', () async {
      final err = StringBuffer();
      final exitCode = await runner.run(
        ['compile', '--json', '${tempDir.path}/prog.json'],
        stderrSink: err,
      );

      expect(exitCode, equals(1));
      expect(err.toString(), contains('would overwrite the input'));
    });
  });

  group('vaster audit', () {
    late Directory tempDir;

    const program = VasterProgram(programName: 'audit_target', instructions: [
      MountFsOp(mountPrefix: '/mem'),
      WriteFileOp(vfsPath: '/mem/report.md', content: 'x'),
      DecideOp(prompt: 'Which way?', branches: [
        DecisionBranch(label: 'left', description: 'go left', targetPc: 4),
        DecisionBranch(label: 'right', description: 'go right', targetPc: 4),
      ], defaultLabel: 'left'),
      HaltOp(),
      HaltOp(),
    ]);

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('vaster_cli_audit_');
      File('${tempDir.path}/prog.json')
          .writeAsStringSync(jsonEncode(program.toJson()));
    });

    tearDown(() async {
      if (await tempDir.exists()) await tempDir.delete(recursive: true);
    });

    test('prints the capability report with the decision surface', () async {
      final out = StringBuffer();
      final exitCode = await runner.run(
        ['audit', '${tempDir.path}/prog.json'],
        stdoutSink: out,
      );

      expect(exitCode, equals(0));
      final report = out.toString();
      expect(report, contains('CAPABILITY AUDIT'));
      expect(report, contains('/mem/report.md'));
      expect(report, contains('Decision surface'));
      expect(report, contains('left→PC:4'));
      expect(report, contains('default=left'));
    });

    test('--json emits a machine-readable audit', () async {
      final out = StringBuffer();
      final exitCode = await runner.run(
        ['audit', '--json', '${tempDir.path}/prog.json'],
        stdoutSink: out,
      );

      expect(exitCode, equals(0));
      final decoded = jsonDecode(out.toString()) as Map<String, dynamic>;
      expect(decoded['programName'], equals('audit_target'));
      expect((decoded['decisions'] as List), hasLength(1));
      expect((decoded['files'] as Map)['staticWrites'],
          contains('/mem/report.md'));
    });
  });

  group('vaster run — compiled artifacts', () {
    late Directory tempDir;

    const program = VasterProgram(programName: 'cli_run', instructions: [
      CreateSessionOp(sessionId: 'cli_sess'),
      SetRegisterOp(registerName: 'x', value: 1),
      HaltOp(),
    ]);

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('vaster_cli_run_');
      File('${tempDir.path}/prog.json')
          .writeAsStringSync(jsonEncode(program.toJson()));
    });

    tearDown(() async {
      if (await tempDir.exists()) await tempDir.delete(recursive: true);
    });

    test('--record writes a replay envelope (journal + model tape)', () async {
      final out = StringBuffer();
      final envelopePath = '${tempDir.path}/envelope.json';
      final exitCode = await runner.run(
        ['run', '--record', envelopePath, '${tempDir.path}/prog.json'],
        stdoutSink: out,
      );

      expect(exitCode, equals(0));
      expect(out.toString(), contains('[record] 3 steps'));

      final envelope = jsonDecode(File(envelopePath).readAsStringSync())
          as Map<String, dynamic>;
      final journal = VasterExecutionJournal.fromJson(
          Map<String, dynamic>.from(envelope['journal'] as Map));
      expect(journal.length, equals(3));
      expect(journal.frames.map((f) => f.pc), equals([0, 1, 2]));
      expect(envelope['modelTape'], isNotNull);
    });

    test('--replay reproduces a recorded run with zero live model calls',
        () async {
      // A program whose outcome depends on a model response.
      const modelProgram =
          VasterProgram(programName: 'taped_run', instructions: [
        PromptOp(promptText: 'name the flagship product', outputVar: 'answer'),
        ConcatRegisterOp(targetVar: '__output__', sourceVars: ['answer']),
        HaltOp(),
      ]);
      File('${tempDir.path}/model_prog.json')
          .writeAsStringSync(jsonEncode(modelProgram.toJson()));
      final envelopePath = '${tempDir.path}/envelope.json';

      // Record against the fake backend.
      final recordOut = StringBuffer();
      expect(
        await runner.run(
          ['run', '--record', envelopePath, '${tempDir.path}/model_prog.json'],
          stdoutSink: recordOut,
        ),
        equals(0),
      );
      expect(recordOut.toString(), contains('1 model calls'));
      final recordedOutput = RegExp(r'output :\n(.*)')
          .firstMatch(recordOut.toString())!
          .group(1)!;

      // Replay from the envelope — --backend is irrelevant now.
      final replayOut = StringBuffer();
      expect(
        await runner.run(
          [
            'run',
            '--replay', envelopePath,
            '--backend', 'claude-api', // must be ignored: no network in replay
            '${tempDir.path}/model_prog.json',
          ],
          stdoutSink: replayOut,
        ),
        equals(0),
      );
      expect(replayOut.toString(), contains('replay tape'));
      expect(replayOut.toString(), contains(recordedOutput),
          reason: 'the replayed run reproduces the recorded model output');
    });

    test('--events prints the runtime event stream as JSON lines', () async {
      final out = StringBuffer();
      final exitCode = await runner.run(
        ['run', '--events', '${tempDir.path}/prog.json'],
        stdoutSink: out,
      );

      expect(exitCode, equals(0));
      expect(out.toString(), contains('[evt] '),
          reason: 'event lines are printed');
      expect(out.toString(), contains('session_created'),
          reason: 'CreateSessionOp telemetry reaches the sink');
    });
  });
}
