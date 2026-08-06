import 'dart:io';

import 'package:test/test.dart';
import 'package:vaster_cli/vaster_cli.dart';
import 'package:vaster_vm/vaster_vm.dart';

/// `vaster check` end to end: proofs and bounds on real program files.
void main() {
  late Directory tmp;
  late VasterCliRunner runner;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('vaster_check_');
    runner = VasterCliRunner();
  });

  tearDown(() => tmp.deleteSync(recursive: true));

  String write(VasterProgram program) {
    final path = '${tmp.path}/${program.programName}.vbc';
    File(path).writeAsBytesSync(program.toBytes());
    return path;
  }

  test('a clean program passes with a finite cost bound', () async {
    final path = write(const VasterProgram(
      programName: 'clean',
      instructions: [
        SetRegisterOp(registerName: 'topic', value: 'checks'),
        PromptOp(promptText: r'write about ${topic}'),
        HaltOp(),
      ],
    ));
    final out = StringBuffer();
    final code = await runner.run(
      ['check', path, '--model', 'claude-sonnet-5', '--policy', 'unlimited'],
      stdoutSink: out,
      stderrSink: out,
    );
    expect(code, 0, reason: out.toString());
    expect(out.toString(), contains('findings: none — clean'));
    expect(out.toString(), contains('≤1 model calls'));
    expect(out.toString(), contains(r'≤$'));
    expect(out.toString(), contains('no proven violations'));
    expect(out.toString(), contains('fully proven'));
  });

  test('a proven policy violation fails the check', () async {
    final path = write(const VasterProgram(
      programName: 'violates',
      instructions: [
        WriteFileOp(vfsPath: '/mem/x.txt', content: 'boom'),
        HaltOp(),
      ],
    ));
    final out = StringBuffer();
    final code = await runner.run(
      ['check', path, '--policy', 'read-only'],
      stdoutSink: out,
      stderrSink: out,
    );
    expect(code, 1);
    expect(out.toString(), contains('PROVEN VIOLATION'));
    expect(out.toString(), contains('WILL trap at runtime'));
  });

  test('--max-cost fails when the worst case exceeds it', () async {
    final path = write(const VasterProgram(
      programName: 'pricey',
      instructions: [
        PromptOp(promptText: 'an expensive thought'),
        HaltOp(),
      ],
    ));
    final out = StringBuffer();
    final code = await runner.run(
      [
        'check', path,
        '--model', 'claude-opus-5',
        '--max-cost', '0.000001',
      ],
      stdoutSink: out,
      stderrSink: out,
    );
    expect(code, 1);
    expect(out.toString(), contains('exceeds --max-cost'));
  });

  test('an unbounded loop fails any --max-cost honestly', () async {
    final path = write(const VasterProgram(
      programName: 'runaway',
      instructions: [
        SetRegisterOp(registerName: 'go', value: true),
        PromptOp(promptText: 'again'),
        JumpIfOp(conditionVar: 'go', targetPc: 1),
        HaltOp(),
      ],
    ));
    final out = StringBuffer();
    final code = await runner.run(
      ['check', path, '--model', 'claude-sonnet-5', '--max-cost', '1000'],
      stdoutSink: out,
      stderrSink: out,
    );
    expect(code, 1);
    expect(out.toString(), contains('unbounded'));
  });
}
