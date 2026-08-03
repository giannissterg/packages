import 'package:test/test.dart';
import 'package:vaster_vm/vaster_vm.dart';

void main() {
  group('RegisterInterpolator', () {
    late RegisterFile registers;
    late RegisterInterpolator interpolator;

    setUp(() {
      registers = RegisterFile();
      interpolator = RegisterInterpolator(registers: registers);
    });

    test('resolves single and adjacent references', () {
      registers.write('name', 'Ada');
      registers.write('role', 'architect');
      expect(interpolator.resolve('Hi ${'\$'}{name}, the ${'\$'}{role}${'\$'}{name}!'),
          equals('Hi Ada, the architectAda!'));
    });

    test(r'$$ escapes to a literal dollar; $${x} stays a literal reference', () {
      registers.write('x', 'v');
      expect(interpolator.resolve(r'cost: $$5'), equals(r'cost: $5'));
      expect(interpolator.resolve(r'template: $${x}'), equals(r'template: ${x}'));
    });

    test('non-string values render as canonical JSON; null renders empty', () {
      registers.write('n', 42);
      registers.write('flag', true);
      registers.write('obj', {'a': 1});
      registers.write('list', [1, 2]);
      registers.write('nothing', null);
      expect(interpolator.resolve(r'${n}|${flag}|${obj}|${list}|${nothing}|'),
          equals('42|true|{"a":1}|[1,2]||'));
    });

    test('missing register left verbatim and reported once per occurrence', () {
      final missing = <String>[];
      final result = interpolator.resolve(r'${ghost} and ${ghost}',
          onMissing: missing.add);
      expect(result, equals(r'${ghost} and ${ghost}'));
      expect(missing, equals(['ghost', 'ghost']));
    });

    test('malformed references and lone dollars are literal', () {
      expect(interpolator.resolve(r'${1x} $ ${'), equals(r'${1x} $ ${'));
    });

    test('no-dollar fast path returns the same string', () {
      const text = 'plain text';
      expect(identical(interpolator.resolve(text), text), isTrue);
    });

    test('resolveMap resolves nested string leaves only', () {
      registers.write('who', 'bob');
      final resolved = interpolator.resolveMap({
        'text': r'for ${who}',
        'count': 3,
        'nested': {
          'inner': r'${who}!',
          'list': [r'${who}', 7],
        },
      });
      expect(resolved, {
        'text': 'for bob',
        'count': 3,
        'nested': {
          'inner': 'bob!',
          'list': ['bob', 7],
        },
      });
    });
  });
}
