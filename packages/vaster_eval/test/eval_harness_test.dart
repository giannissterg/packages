import 'package:test/test.dart';
import 'package:vaster_eval/vaster_eval.dart';
import 'package:vaster_model_fake/vaster_model_fake.dart';
import 'package:vaster_vm/vaster_vm.dart';

/// The harness turns "it ran" into "it works, N times out of M, at $X".
void main() {
  const program = VasterProgram(
    programName: 'verdict_writer',
    resultBinding: 'verdict',
    instructions: [
      PromptOp(promptText: 'judge readiness', outputVar: 'verdict'),
      HaltOp(),
    ],
  );

  EvalVariant variant(String label, VasterModel Function() model) =>
      EvalVariant(
        label: label,
        program: program,
        vmFactory: () async =>
            VasterVMEngine.bootstrap(config: VMConfig(defaultModel: model())),
        dispose: (vm) => (vm as VasterVMEngine).shutdown(),
      );

  test('a deterministic passing variant scores 100% with metered totals',
      () async {
    final harness = EvalHarness(
      scorer: const AllOfScorer([HaltedScorer(), ContainsScorer('GO')]),
      trialsPerVariant: 3,
    );
    final report = await harness.run([
      variant('always_go',
          () => FakeVasterModel(defaultResponseText: 'verdict: GO')),
    ]);

    final v = report.variants.single;
    expect(v.trialCount, 3);
    expect(v.successRate, 1.0);
    expect(v.meanScore, 1.0);
    expect(v.totalTokens, greaterThan(0),
        reason: 'trials carry real metered numbers');
    expect(v.trials.every((t) => t.wallClock >= Duration.zero), isTrue);
  });

  test('a FLAKY model yields an honest fractional success rate', () async {
    // Alternates GO / NO across calls — every fresh-VM trial makes exactly
    // one call, so trials alternate pass/fail.
    var call = 0;
    VasterModel flaky() => FakeVasterModel(handler: (request) async {
          call++;
          return ModelResponse(
            message:
                ChatMessage.model(call.isOdd ? 'verdict: GO' : 'verdict: NO'),
            finishReason: FinishReason.stop,
          );
        });

    final harness = EvalHarness(
      scorer: const ContainsScorer('GO'),
      trialsPerVariant: 4,
    );
    final report = await harness.run([variant('flaky', flaky)]);

    final v = report.variants.single;
    expect(v.successRate, 0.5,
        reason: '2 of 4 trials pass — the number no single run can give you');
    expect(v.passed, 2);
    final failing = v.trials.where((t) => !t.score.passed);
    expect(failing.every((t) => t.score.detail!.contains('GO')), isTrue,
        reason: 'failures carry their diagnostic');
  });

  test('variants are comparable side by side in one report', () async {
    final harness = EvalHarness(
        scorer: const ContainsScorer('GO'), trialsPerVariant: 2);
    final report = await harness.run([
      variant('good', () => FakeVasterModel(defaultResponseText: 'GO')),
      variant('bad', () => FakeVasterModel(defaultResponseText: 'NO')),
    ]);

    expect(report.variants, hasLength(2));
    expect(report.variants[0].successRate, 1.0);
    expect(report.variants[1].successRate, 0.0);
    final json = report.toJson();
    expect((json['variants'] as List), hasLength(2),
        reason: 'the report is a serializable artifact');
  });

  test('a trapping program fails the HaltedScorer with its trap detail',
      () async {
    const trapping = VasterProgram(
      programName: 'traps',
      instructions: [
        ReadFileOp(vfsPath: '/not_mounted/x.txt'),
        HaltOp(),
      ],
    );
    final harness =
        EvalHarness(scorer: const HaltedScorer(), trialsPerVariant: 1);
    final report = await harness.run([
      EvalVariant(
        label: 'trapper',
        program: trapping,
        vmFactory: () async => VasterVMEngine.bootstrap(
            config: VMConfig(defaultModel: FakeVasterModel())),
        dispose: (vm) => (vm as VasterVMEngine).shutdown(),
      ),
    ]);

    final trial = report.variants.single.trials.single;
    expect(trial.score.passed, isFalse);
    expect(trial.score.detail, contains('error'));
    expect(report.variants.single.successRate, 0.0);
  });
}
