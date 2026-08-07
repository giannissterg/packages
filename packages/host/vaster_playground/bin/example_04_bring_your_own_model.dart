import 'dart:io';

import 'package:vaster/vaster.dart';

/// Example 04 — bring your own model, keep the machine.
///
/// You already call an LLM — through your SDK, your company's proxy, or a
/// local server. `VasterModel.fromHandler` wraps THAT call; the framework
/// provides what the call does not: compilation, budgets, durability,
/// and — shown here — recording and zero-cost replay.
///
/// Act I runs the pipeline through "your" model call and records the run.
/// Act II replays the SAME pipeline from the recording: zero live calls,
/// zero cost, identical result — the way LLM workflows get tested in CI.
///
///     dart run vaster_playground:example_04_bring_your_own_model
void main() async {
  // ── Your existing model call. Imagine an SDK invocation here — the
  // framework neither knows nor cares how tokens are produced.
  var liveCalls = 0;
  Future<String> myExistingModelCall(String latestTurn) async {
    liveCalls++;
    return latestTurn.contains('haiku')
        ? 'Registers hold state,\nthe journal remembers all —\nreplay is for free.'
        : 'A recorded run can be replayed later at zero cost.';
  }

  const pipeline = Pipeline(
    name: 'byom_demo',
    result: Binding('haiku'),
    children: [
      Prompt(Template.text('State one fact about vaster recordings.'), output: Binding('fact')),
      Prompt(Template(['Turn this into a haiku:\n', Binding('fact')]), output: Binding('haiku')),
    ],
  );

  // ── Act I: live run on YOUR call, recorded.
  final recordPath = '${Directory.systemTemp.createTempSync('vaster_ex04_').path}/run.replay.json';
  final live = await runPipeline(
    pipeline,
    backend: VasterModel.fromTextHandler(
      (request) => myExistingModelCall(request.messages.last.text),
      modelName: 'my-own-model',
    ),
    record: recordPath,
  );
  print('── live run (your model call, $liveCalls invocations) ──');
  print(live);

  // ── Act II: the same pipeline, replayed from the tape. Zero live calls.
  final replay = await runPipeline(
    pipeline,
    backend: ReplayVasterModel(
      tape: const ReplayEnvelopeCodec().decodeString(File(recordPath).readAsStringSync()).tape,
    ),
  );
  print('── replay (zero live calls — your CI runs this for \$0) ──');
  print(replay);
  print('live invocations after both runs: $liveCalls');
}
