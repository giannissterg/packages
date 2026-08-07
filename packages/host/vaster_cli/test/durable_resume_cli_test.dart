import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:vaster_cli/vaster_cli.dart';
import 'package:vaster_vm/vaster_vm.dart';

/// The durable park/resume loop through the real CLI verbs:
/// `vaster run --checkpoint-dir` exits with a checkpoint file instead of
/// holding the process; `vaster resume --respond` finishes the run in a
/// completely separate VM.
void main() {
  late Directory tmp;
  late VasterCliRunner runner;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('vaster_durable_');
    runner = VasterCliRunner();
  });

  tearDown(() => tmp.deleteSync(recursive: true));

  /// prompt → gate → post-gate file write + result register.
  VasterProgram gatedProgram() => VasterProgram(
        programName: 'parkme',
        resultBinding: 'outcome',
        instructions: [
          const CreateSessionOp(sessionId: 'sess_run'),
          const SetSessionOp(sessionId: 'sess_run'),
          const PromptOp(promptText: 'pre-gate turn', outputVar: 'pre'),
          YieldHumanInteractionOp(
            request: const HumanInteractionRequest(
              requestId: 'ship_gate',
              type: HumanInteractionType.approval,
              prompt: 'ship it?',
              options: ['approve', 'reject'],
              outputVar: 'ship',
            ),
          ),
          const SetRegisterOp(registerName: 'outcome', value: 'shipped'),
          const HaltOp(),
        ],
      );

  test('run parks durably (exit 3 + checkpoint file); resume completes', () async {
    final programPath = '${tmp.path}/parkme.vbc';
    File(programPath).writeAsBytesSync(gatedProgram().toBytes());
    final ckptDir = '${tmp.path}/ckpts';

    // ── vaster run --checkpoint-dir → parks, does not prompt ──
    final runOut = StringBuffer();
    final runCode = await runner.run(
      ['run', programPath, '--backend', 'fake', '--checkpoint-dir', ckptDir],
      stdoutSink: runOut,
      stderrSink: runOut,
    );
    expect(runCode, 3, reason: runOut.toString());
    expect(runOut.toString(), contains('PARKED (durable)'));

    final ckptFile = File('$ckptDir/parkme_ship_gate.ckpt.json');
    expect(ckptFile.existsSync(), isTrue);
    // The file is self-contained: program + machine + meters.
    final json = jsonDecode(ckptFile.readAsStringSync()) as Map;
    expect(json['programVbcBase64'], isNotNull);
    expect(json['continuation'], isNotNull);

    // ── vaster resume --respond approve → completes in a fresh VM ──
    final resumeOut = StringBuffer();
    final resumeCode = await runner.run(
      ['resume', ckptFile.path, '--backend', 'fake', '--respond', 'approve'],
      stdoutSink: resumeOut,
      stderrSink: resumeOut,
    );
    expect(resumeCode, 0, reason: resumeOut.toString());
    final output = resumeOut.toString();
    expect(output, contains('DURABLE RESUME'));
    expect(output, contains('status : halted'));
    expect(output, contains('shipped'), reason: 'the declared result register is reported after resume');
  });

  test('resume rejects a corrupt checkpoint with a clear error', () async {
    final bad = File('${tmp.path}/bad.ckpt.json')..writeAsStringSync('{"formatVersion": 99}');
    final out = StringBuffer();
    final code = await runner.run(
      ['resume', bad.path, '--backend', 'fake'],
      stdoutSink: out,
      stderrSink: out,
    );
    expect(code, 1);
    expect(out.toString(), contains('format v99'));
  });
}
