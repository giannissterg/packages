import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:vaster/vaster.dart';

/// F0 (AST_REVIEW): runPipeline is the runApp of vaster — the whole
/// compile → bootstrap → execute → report harness in one call, with
/// recording and artifact collection owned by the facade.
void main() {
  Pipeline buildPipeline() => const Pipeline(
        name: 'facade_probe',
        result: Binding('summary'),
        children: [
          Prompt(Template.text('Draft the notes.'), output: Binding('notes')),
          WriteFile(path: Template.text('/mem/notes.txt'), content: Template([Binding('notes')])),
          Prompt(Template(['Summarize:\n', Binding('notes')]), output: Binding('summary')),
        ],
      );

  test('one call: compile, execute, report — result, meters, artifacts', () async {
    final report = await runPipeline(
      buildPipeline(),
      backend: FakeVasterModel(
        handler: (request) => ModelResponse(
          message: ChatMessage.model(
            request.messages.last.text.contains('Summarize') ? 'THE-SUMMARY' : 'THE-NOTES',
          ),
        ),
      ),
    );

    expect(report.succeeded, isTrue, reason: 'error: ${report.state.errorDetails}');
    expect('${report.result}', contains('THE-SUMMARY'));
    expect(report.consumedTokens, greaterThan(0));
    expect(
      report.artifacts.map((a) => a.path),
      contains('/mem/notes.txt'),
      reason: 'artifacts come from the run\'s own FileOperationEvent writes',
    );
    expect(report.envelopePath, isNull);
    expect('$report', contains('status  : halted'));
  });

  test('record: writes a replay envelope the codec round-trips', () async {
    final tmp = Directory.systemTemp.createTempSync('vaster_facade_');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final envelopePath = '${tmp.path}/run.replay.json';

    final report = await runPipeline(
      buildPipeline(),
      backend: FakeVasterModel(),
      record: envelopePath,
    );

    expect(report.succeeded, isTrue);
    expect(report.envelopePath, envelopePath);
    final envelope = const ReplayEnvelopeCodec().decodeString(File(envelopePath).readAsStringSync());
    expect(envelope.tape.entries, hasLength(2), reason: 'both prompts rode the tape');
    expect(envelope.programJson, isNotNull, reason: 'the envelope embeds its program');
    expect(envelope.journal.length, greaterThan(0));
  });

  test('a failing pipeline still tears the VM down and reports honestly', () async {
    final report = await runPipeline(
      const Pipeline(
        name: 'reads_missing_file',
        children: [ReadFile(path: Template.text('/mem/never_written.txt'), output: Binding('x'))],
      ),
      backend: FakeVasterModel(),
    );
    expect(report.succeeded, isFalse);
    expect(report.state.status, RuntimeStatus.error);
    expect('$report', contains('error'));
  });

  test('bring-your-own-model: a handler-wrapped call runs, records, and replays', () async {
    final tmp = Directory.systemTemp.createTempSync('vaster_byom_');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final envelopePath = '${tmp.path}/byom.replay.json';

    // "Your existing SDK call" — any function producing text.
    var liveCalls = 0;
    Future<String> myExistingSdkCall(String conversation) async {
      liveCalls++;
      return conversation.contains('Summarize') ? 'BYOM-SUMMARY' : 'BYOM-NOTES';
    }

    final report = await runPipeline(
      buildPipeline(),
      backend: VasterModel.fromTextHandler(
        (request) => myExistingSdkCall(request.messages.last.text),
        modelName: 'my-own-model',
      ),
      record: envelopePath,
    );
    expect(report.succeeded, isTrue, reason: 'error: ${report.state.errorDetails}');
    expect('${report.result}', contains('BYOM-SUMMARY'));
    expect(liveCalls, 2);

    // The zero-cost story: the recording replays the SAME pipeline with
    // ZERO live calls.
    final replayReport = await runPipeline(
      buildPipeline(),
      backend: ReplayVasterModel(
        tape: const ReplayEnvelopeCodec().decodeString(File(envelopePath).readAsStringSync()).tape,
      ),
    );
    expect(replayReport.succeeded, isTrue);
    expect('${replayReport.result}', contains('BYOM-SUMMARY'));
    expect(liveCalls, 2, reason: 'replay made no live calls');
  });

  test('envelope JSON is valid JSON on disk', () async {
    final tmp = Directory.systemTemp.createTempSync('vaster_facade_json_');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final path = '${tmp.path}/r.json';
    await runPipeline(buildPipeline(), backend: FakeVasterModel(), record: path);
    expect(jsonDecode(File(path).readAsStringSync()), isA<Map<String, dynamic>>());
  });
}
