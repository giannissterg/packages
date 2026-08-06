import 'package:test/test.dart';
import 'package:vaster_model/vaster_model.dart';

void main() {
  group('ModelDescriptor Primitive', () {
    test('creates ModelDescriptor with provider and modelId', () {
      const descriptor = ModelDescriptor(
        provider: 'gemini_cli',
        modelId: 'gemini-2.5-flash',
      );
      expect(descriptor.provider, equals('gemini_cli'));
      expect(descriptor.modelId, equals('gemini-2.5-flash'));
      expect(descriptor.descriptorKey, equals('gemini_cli:gemini-2.5-flash'));
    });

    test('serializes to JSON and round-trips correctly', () {
      const descriptor = ModelDescriptor(
        provider: 'google_ai',
        modelId: 'gemini-1.5-pro',
        parameters: {'temperature': '0.7'},
      );
      final json = descriptor.toJson();
      final restored = ModelDescriptor.fromJson(json);

      expect(restored.provider, equals('google_ai'));
      expect(restored.modelId, equals('gemini-1.5-pro'));
      expect(restored.parameters['temperature'], equals('0.7'));
    });

    test('factory constructors create expected descriptors', () {
      const fake = ModelDescriptor.fake();
      expect(fake.provider, equals('fake'));
      expect(fake.modelId, equals('default'));

      const cli = ModelDescriptor.geminiCli(modelId: 'gemini-2.5-flash');
      expect(cli.descriptorKey, equals('gemini_cli:gemini-2.5-flash'));

      const google = ModelDescriptor.googleAi(modelId: 'gemini-1.5-pro');
      expect(google.descriptorKey, equals('google_ai:gemini-1.5-pro'));
    });
  });
}
