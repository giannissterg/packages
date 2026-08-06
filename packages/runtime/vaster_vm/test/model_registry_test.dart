import 'package:test/test.dart';
import 'package:vaster_model_fake/vaster_model_fake.dart';
import 'package:vaster_vm/vaster_vm.dart';

void main() {
  group('ModelRegistry & VasterVirtualMachine', () {
    late FakeVasterModel defaultModel;
    late FakeVasterModel cliModel;

    setUp(() {
      defaultModel = FakeVasterModel(modelName: 'default-fake');
      cliModel = FakeVasterModel(modelName: 'gemini-cli-fake');
    });

    test('registers and resolves models by ModelDescriptor', () {
      final registry = ModelRegistry(defaultModel: defaultModel);
      const cliDescriptor = ModelDescriptor.geminiCli(modelId: 'gemini-2.5-flash');

      registry.registerModel(cliDescriptor, cliModel);

      expect(registry.resolveModel(cliDescriptor), equals(cliModel));
      expect(registry.resolveByKey('gemini_cli:gemini-2.5-flash'), equals(cliModel));
      expect(registry.resolveByKey('gemini_cli'), equals(cliModel));
    });

    test('falls back to defaultModel when no descriptor match is found', () {
      final registry = ModelRegistry(defaultModel: defaultModel);
      const unknownDescriptor = ModelDescriptor(provider: 'unknown', modelId: 'none');

      expect(registry.resolveModel(unknownDescriptor), equals(defaultModel));
    });

    test('VasterVirtualMachine registers models via vm.registerModel()', () async {
      final vm = await VasterVMEngine.bootstrap(
        config: VMConfig(defaultModel: defaultModel),
      );

      const descriptor = ModelDescriptor.geminiCli();
      vm.registerModel(descriptor, cliModel);

      expect(vm.modelRegistry.resolveModel(descriptor), equals(cliModel));
    });
  });
}
