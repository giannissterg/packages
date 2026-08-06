import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:vaster_calibration/vaster_calibration.dart';
import 'package:vaster_model/vaster_model.dart';
import 'package:vaster_replay/vaster_replay.dart';
import 'package:vaster_token_estimate/vaster_token_estimate.dart';

/// Roadmap item 4's deliverable, kept honest: fitted profiles are
/// re-derived from the committed fixture on every run, and the error
/// bounds are ASSERTED — including the claim that calibration beats the
/// flat heuristic on the very data it was fitted from.
void main() {
  ModelTape fixtureTape() {
    final envelope = jsonDecode(File(
                '../../host/vaster_playground/test/fixtures/sdd_fidelity.replay.json')
            .readAsStringSync())
        as Map<String, dynamic>;
    return ModelTape.fromJson(
        Map<String, dynamic>.from(envelope['modelTape'] as Map));
  }

  group('TapeCalibrationFitter on the committed fixture', () {
    late CalibrationFit fit;
    setUpAll(() => fit = const TapeCalibrationFitter().fit(fixtureTape(),
        backendId: 'gemini-2.0-flash',
        provenance: 'sdd_fidelity.replay.json (paid run, 2026-08)'));

    test('re-derived profile matches the committed constants', () {
      expect(fit.calibration.charsPerToken,
          closeTo(CalibrationCatalog.geminiFlash.charsPerToken, 1e-9),
          reason: 'the builtin catalog must be refittable from the fixture '
              '— committed numbers cannot silently rot');
      expect(fit.calibration.sampleCount,
          CalibrationCatalog.geminiFlash.sampleCount);
    });

    test('exclusion is loud: the implausible sample is reported', () {
      expect(fit.excludedSamples, 1,
          reason: 'one fixture call has more tokens than characters — '
              'physically impossible for plain text, excluded and counted');
      expect(fit.calibration.provenance, contains('1 implausible excluded'));
    });

    test('error bounds hold — and beat the flat heuristic', () {
      expect(fit.meanAbsErrorFraction, lessThan(0.20),
          reason: 'fixture mean error stays under 20%');
      expect(fit.maxAbsErrorFraction, lessThan(0.40));

      // The heuristic's error on the same plausible samples.
      final calibrated = CalibratedTokenEstimator(fit.calibration);
      var heuristicErr = 0.0;
      var calibratedErr = 0.0;
      var n = 0;
      for (final entry in fixtureTape().entries) {
        final response = ModelResponse.fromJson(entry.responseJson);
        final tokens = response.usage.candidatesTokenCount;
        final chars = response.text.length;
        if (tokens <= 0 || chars <= 0 || chars / tokens < 1.5) continue;
        heuristicErr +=
            (TokenEstimate.forText(response.text) - tokens).abs() / tokens;
        calibratedErr +=
            (calibrated.forText(response.text) - tokens).abs() / tokens;
        n++;
      }
      expect(n, fit.calibration.sampleCount);
      expect(calibratedErr / n, lessThan(heuristicErr / n),
          reason: 'the entire point: fitted knowledge estimates the '
              'fixture strictly better than len/4');
    });
  });

  group('fitter refuses to lie', () {
    ModelTapeEntry entry(String text, int tokens) => ModelTapeEntry(
          fingerprint: 'f$text$tokens',
          requestPreview: 'p',
          responseJson: ModelResponse(
            message: ChatMessage.model(text),
            usage: UsageMetadata(
                candidatesTokenCount: tokens,
                promptTokenCount: 1,
                source: UsageSource.measured),
          ).toJson(),
        );

    test('too few plausible samples is an error, not a guess', () {
      final tape = ModelTape(entries: [
        entry('aaaa bbbb cccc', 4),
        entry('x', 5), // implausible — excluded
      ]);
      expect(
          () => const TapeCalibrationFitter()
              .fit(tape, backendId: 'b', provenance: 'test'),
          throwsA(isA<StateError>().having((e) => e.message, 'message',
              contains('refusing to fit'))));
    });

    test('estimated-source usage never contributes to a fit', () {
      final tape = ModelTape(entries: [
        for (var i = 0; i < 5; i++)
          ModelTapeEntry(
            fingerprint: 'f$i',
            requestPreview: 'p',
            responseJson: ModelResponse(
              message: ChatMessage.model('some text here padding $i'),
              usage: const UsageMetadata(
                  candidatesTokenCount: 6, source: UsageSource.estimated),
            ).toJson(),
          ),
      ]);
      expect(
          () => const TapeCalibrationFitter()
              .fit(tape, backendId: 'b', provenance: 'test'),
          throwsStateError,
          reason: 'fitting estimates to estimates would launder the '
              'heuristic into fake measurement');
    });
  });

  group('CalibratedTokenEstimator composes with the seam', () {
    test('implements the same TokenEstimator contract as the heuristic',
        () {
      const TokenEstimator heuristic = HeuristicTokenEstimator();
      final TokenEstimator calibrated =
          CalibratedTokenEstimator(CalibrationCatalog.geminiFlash);
      const text = 'Some representative stretch of English prose.';
      expect(heuristic.forText(text), TokenEstimate.forText(text),
          reason: 'the default delegates — identical by construction');
      expect(calibrated.forText(text), isNot(heuristic.forText(text)),
          reason: 'fitted knowledge changes the number');
      expect(
          calibrated
              .forExchange(prompt: text, output: text)
              .source,
          UsageSource.estimated,
          reason: 'calibration narrows error; it never claims measurement');
    });
  });

  test('claude-cli overhead factor carries its weakness openly', () {
    const profile = CalibrationCatalog.claudeCliAgentic;
    expect(profile.callOverheadFactor, closeTo(0.1157 / 0.0518, 0.01),
        reason: 'the factor IS the prove-it measurement');
    expect(profile.sampleCount, 1);
    expect(profile.provenance, contains('n=1'));
  });

  group('CalibrationCatalog is an instance, composable', () {
    test('builtin lookup and miss', () {
      expect(CalibrationCatalog.builtin.forBackend('gemini-2.0-flash'),
          same(CalibrationCatalog.geminiFlash));
      expect(CalibrationCatalog.builtin.forBackend('unknown'), isNull);
    });

    test('a custom catalog composes without touching the builtin', () {
      const mine = CalibrationCatalog([
        EstimateCalibration(
            backendId: 'my-local',
            charsPerToken: 3.2,
            sampleCount: 10,
            provenance: 'test'),
      ]);
      expect(mine.forBackend('my-local')!.charsPerToken, 3.2);
      expect(mine.forBackend('gemini-2.0-flash'), isNull,
          reason: 'catalogs are values — no hidden global registry');
    });
  });
}
