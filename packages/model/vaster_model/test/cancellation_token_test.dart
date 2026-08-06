import 'package:test/test.dart';
import 'package:vaster_model/vaster_model.dart';

void main() {
  group('CancellationToken', () {
    test('starts uncancelled and throws after cancel call', () {
      final token = CancellationToken();
      expect(token.isCancelled, isFalse);
      expect(() => token.throwIfCancelled(), returnsNormally);

      token.cancel('User requested stop');
      expect(token.isCancelled, isTrue);
      expect(token.reason, equals('User requested stop'));
      expect(() => token.throwIfCancelled(), throwsA(isA<CancelledException>()));
    });
  });
}
