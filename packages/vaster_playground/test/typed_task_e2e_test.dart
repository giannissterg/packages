import 'package:test/test.dart';
import 'package:vaster_ast/vaster_ast.dart';
import 'package:vaster_compiler/vaster_compiler.dart';
import 'package:vaster_domain/vaster_domain.dart';
import 'package:vaster_model_fake/vaster_model_fake.dart';
import 'package:vaster_vm/vaster_vm.dart';

/// Compiler → ISA → runtime E2E coverage for typed task outputs.
///
/// ISA-level typed-output behavior (PromptOp.responseSchema) is tested in
/// `vaster_runtime/test/typed_output_runtime_test.dart`.
void main() {
  group('Typed model outputs — compiled pipeline', () {
    late FakeVasterModel fakeModel;
    late VasterVirtualMachine vm;
    late VasterRuntime runtime;

    setUp(() async {
      fakeModel = FakeVasterModel();
      vm = await VasterVMEngine.bootstrap(config: VMConfig(defaultModel: fakeModel));
      runtime = VasterRuntime(
        vm: vm,
        policy: ExecutionPolicy.unlimited,
        budget: ExecutionBudget.unlimited(),
        scheduler: BasicVasterScheduler(taskQueue: PriorityTaskQueue()),
      );
    });

    tearDown(() async {
      await vm.shutdown();
    });

    test('Task.outputSchema flows compiler -> ISA -> agent -> model request', () async {
      const architect = AgentRole(
        roleId: 'architect',
        name: 'Architect',
        title: 'Architect',
        instruction: 'Design.',
      );
      final schema = {
        'type': 'object',
        'properties': {
          'design': {'type': 'string'},
        },
        'required': ['design'],
        'additionalProperties': false,
      };

      final program = const BasicWorkflowCompiler().compile(Pipeline(
        name: 'typed_task',
        roles: const [architect],
        children: [
          Agent(
              role: architect,
              child: Task(prompt: Template.text('design the notes app'), outputSchema: schema)),
        ],
      ));

      final state = await runtime.executeProgram(program);
      expect(state.status, equals(RuntimeStatus.halted));

      // The agent's ModelRequest must carry the schema end to end.
      final typedRequests = fakeModel.recordedRequests
          .where((r) => r.generationConfig.responseSchema != null);
      expect(typedRequests, isNotEmpty,
          reason: 'agent request should carry the task outputSchema');
      expect(typedRequests.first.generationConfig.responseSchema, equals(schema));
    });
  });
}
