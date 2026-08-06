import 'package:test/test.dart';
import 'package:vaster_runtime/vaster_runtime.dart';

/// The sealed extraction model: tolerant, but every failure shape is typed
/// data the engine can surface.
void main() {
  group('RegisterFile.jsonExtract outcomes', () {
    late RegisterFile registers;

    setUp(() => registers = RegisterFile());

    test('a present key extracts and reports ExtractOk with the value', () {
      registers.write('src', '{"verdict": "GO", "score": 3}');
      final outcome = registers.jsonExtract(
          sourceVar: 'src', jsonKey: 'verdict', targetVar: 'out');
      expect(outcome, isA<ExtractOk>().having((o) => o.value, 'value', 'GO'));
      expect(registers.read('out'), equals('GO'));
    });

    test('an unset source reports ExtractSourceMissing, target unset', () {
      final outcome = registers.jsonExtract(
          sourceVar: 'ghost', jsonKey: 'k', targetVar: 'out');
      expect(outcome,
          isA<ExtractSourceMissing>().having((o) => o.sourceVar, 'src', 'ghost'));
      expect(registers.read('out'), isNull);
    });

    test('unparseable JSON reports ExtractParseFailure, target unset', () {
      registers.write('src', 'this is prose, not JSON');
      final outcome = registers.jsonExtract(
          sourceVar: 'src', jsonKey: 'k', targetVar: 'out');
      expect(outcome, isA<ExtractParseFailure>());
      expect(registers.read('out'), isNull);
    });

    test('a non-object JSON value reports ExtractParseFailure', () {
      registers.write('src', '[1, 2, 3]');
      final outcome = registers.jsonExtract(
          sourceVar: 'src', jsonKey: 'k', targetVar: 'out');
      expect(
          outcome,
          isA<ExtractParseFailure>()
              .having((o) => o.detail, 'detail', contains('not a JSON object')));
    });

    test('a missing key reports ExtractKeyMissing with the available keys',
        () {
      registers.write('src', '{"Verdict": "GO", "confidence": 0.9}');
      final outcome = registers.jsonExtract(
          sourceVar: 'src', jsonKey: 'verdict', targetVar: 'out');
      expect(
        outcome,
        isA<ExtractKeyMissing>()
            .having((o) => o.jsonKey, 'jsonKey', 'verdict')
            .having((o) => o.availableKeys, 'availableKeys',
                containsAll(['Verdict', 'confidence'])),
        reason: 'the diagnostic must reveal the casing mismatch',
      );
      expect(registers.read('out'), isNull);
    });

    test('an already-decoded Map source extracts without re-parsing', () {
      registers.write('src', {'nested': true});
      final outcome = registers.jsonExtract(
          sourceVar: 'src', jsonKey: 'nested', targetVar: 'out');
      expect(outcome, isA<ExtractOk>());
      expect(registers.read('out'), isTrue);
    });
  });
}
