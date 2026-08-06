import 'dart:convert';

import 'package:test/test.dart';
import 'package:vaster_machine_state/vaster_machine_state.dart';

final class _FakeComponent implements MachineStateComponent {
  @override
  final String stateKey;
  Map<String, dynamic> state;

  _FakeComponent(this.stateKey, this.state);

  @override
  Map<String, dynamic> captureState() => Map.of(state);

  @override
  void restoreState(Map<String, dynamic> snapshot) => state = Map.of(snapshot);
}

void main() {
  group('MachineSnapshot', () {
    test('capture folds every registered component; restore dispatches back',
        () {
      final a = _FakeComponent('a', {'x': 1});
      final b = _FakeComponent('b', {'y': 'two'});
      final snapshot =
          MachineSnapshot.capture(pc: 7, componentList: [a, b]);

      final a2 = _FakeComponent('a', {});
      final b2 = _FakeComponent('b', {});
      MachineSnapshot.fromJson(
              jsonDecode(jsonEncode(snapshot.toJson())) as Map<String, dynamic>)
          .restoreInto([a2, b2]);

      expect(a2.state, {'x': 1});
      expect(b2.state, {'y': 'two'});
    });

    test('restore refuses to drop state for an unknown component key', () {
      final snapshot = MachineSnapshot(pc: 0, components: const {
        'ghost': {'lost': true},
      });
      expect(() => snapshot.restoreInto([_FakeComponent('a', {})]),
          throwsA(isA<StateError>()));
    });

    test('unknown format versions are rejected', () {
      expect(
        () => MachineSnapshot.fromJson(const {'formatVersion': 42, 'pc': 0}),
        throwsA(isA<FormatException>()),
      );
    });

    test('ErrorHandlerFrame round-trips', () {
      const frame = ErrorHandlerFrame(targetPc: 12, errorVar: 'err');
      final restored = ErrorHandlerFrame.fromJson(
          jsonDecode(jsonEncode(frame.toJson())) as Map<String, dynamic>);
      expect(restored.targetPc, 12);
      expect(restored.errorVar, 'err');
    });
  });
}
