import 'dart:io';

import 'package:test/test.dart';
import 'package:vaster_cli/vaster_cli.dart';
import 'package:vaster_vm/vaster_vm.dart';

/// `vaster eval` end to end on the fake backend.
void main() {
  late Directory tmp;
  late VasterCliRunner runner;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('vaster_eval_cli_');
    runner = VasterCliRunner();
  });

  tearDown(() => tmp.deleteSync(recursive: true));

  test('a passing program reports 100% and exits 0', () async {
    final path = '${tmp.path}/echo.vbc';
    File(path).writeAsBytesSync(const VasterProgram(
      programName: 'echo',
      resultBinding: 'r',
      instructions: [
        PromptOp(promptText: 'say something', outputVar: 'r'),
        HaltOp(),
      ],
    ).toBytes());

    final out = StringBuffer();
    final code = await runner.run(
      ['eval', path, '--trials', '2', '--contains', 'Echo'],
      stdoutSink: out,
      stderrSink: out,
    );
    expect(code, 0, reason: out.toString());
    expect(out.toString(), contains('success : 2/2 (100%)'));
    expect(out.toString(), contains('tokens'));
  });

  test('a failing assertion reports the diagnostic and exits 1', () async {
    final path = '${tmp.path}/echo.vbc';
    File(path).writeAsBytesSync(const VasterProgram(
      programName: 'echo',
      resultBinding: 'r',
      instructions: [
        PromptOp(promptText: 'say something', outputVar: 'r'),
        HaltOp(),
      ],
    ).toBytes());

    final out = StringBuffer();
    final code = await runner.run(
      ['eval', path, '--trials', '2', '--contains', 'IMPOSSIBLE_TOKEN'],
      stdoutSink: out,
      stderrSink: out,
    );
    expect(code, 1);
    expect(out.toString(), contains('success : 0/2 (0%)'));
    expect(out.toString(), contains('IMPOSSIBLE_TOKEN'), reason: 'failures carry their diagnostic');
  });
}
