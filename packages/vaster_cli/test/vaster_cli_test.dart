import 'package:test/test.dart';
import 'package:vaster_cli/vaster_cli.dart';

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
}
