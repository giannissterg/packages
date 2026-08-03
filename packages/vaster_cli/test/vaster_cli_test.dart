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

    test('--record writes a replayable execution journal', () async {
      final out = StringBuffer();
      final journalPath = '${tempDir.path}/journal.json';
      final exitCode = await runner.run(
        ['run', '--record', journalPath, '${tempDir.path}/prog.json'],
        stdoutSink: out,
      );

      expect(exitCode, equals(0));
      expect(out.toString(), contains('[record] 3 steps'));

      final journal = VasterExecutionJournal.fromJson(
          jsonDecode(File(journalPath).readAsStringSync())
              as Map<String, dynamic>);
      expect(journal.length, equals(3));
      expect(journal.frames.map((f) => f.pc), equals([0, 1, 2]));
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
