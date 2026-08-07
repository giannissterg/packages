import 'package:test/test.dart';
import 'package:vaster_model_fake/vaster_model_fake.dart';
import 'package:vaster_vm/vaster_vm.dart';

/// The program-header class table installs at load, and AddContextOp regions
/// resolve against it.
void main() {
  test('executeProgram installs the header table; regions carry classes', () async {
    final vm = await VasterVMEngine.bootstrap(config: VMConfig(defaultModel: FakeVasterModel()));
    final runtime = VasterRuntime(
      vm: vm,
      policy: ExecutionPolicy.unlimited,
      budget: ExecutionBudget.unlimited(),
      scheduler: BasicVasterScheduler(taskQueue: PriorityTaskQueue()),
    );

    final program = VasterProgram(
      programName: 'header_install',
      contextClasses: ContextClassTable.standard.withOverrides([
        const ContextClass(name: 'domain_docs', band: 22, cacheStable: true),
      ]).toJson(),
      instructions: const [
        AddContextOp(
          regionId: 'doc1',
          label: 'API doc',
          text: 'The API returns things.',
          className: 'domain_docs',
        ),
        HaltOp(),
      ],
    );

    final state = await runtime.executeProgram(program);

    expect(state.status, equals(RuntimeStatus.halted));
    expect(vm.contextManager.classTable.contains('domain_docs'), isTrue);
    final region = vm.contextManager.getRegion('doc1')!;
    expect(region.classId, equals('domain_docs'));
    expect(region.priority, isNull, reason: 'inherits from the class');
  });
}
