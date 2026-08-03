import 'package:test/test.dart';
import 'package:vaster_ast/vaster_ast.dart';
import 'package:vaster_compiler/vaster_compiler.dart';
import 'package:vaster_domain/vaster_domain.dart';
import 'package:vaster_model_fake/vaster_model_fake.dart';
import 'package:vaster_vm/vaster_vm.dart';

void main() {
  group('Typed model outputs — end-to-end schema flow', () {
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

    test('PromptOp.responseSchema reaches the model as generationConfig', () async {
      final schema = {
        'type': 'object',
        'properties': {
          'answer': {'type': 'string'},
        },
        'required': ['answer'],
        'additionalProperties': false,
      };
      final program = VasterProgram(programName: 'typed_prompt', instructions: [
        PromptOp(promptText: 'answer me', outputVar: 'r0', responseSchema: schema),
        const HaltOp(),
      ]);

      final state = await runtime.executeProgram(program);
      expect(state.status, equals(RuntimeStatus.halted));

      final request = fakeModel.recordedRequests.single;
      expect(request.generationConfig.responseSchema, equals(schema));
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
        spec: const PipelineSpec(name: 'typed_task'),
        roles: const [architect],
        children: [
          Agent(role: architect, children: [
            Task(taskPrompt: 'design the notes app', outputSchema: schema),
          ]),
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

    test('runtime error produces a structured VM trap report', () async {
      const program = VasterProgram(programName: 'trap_demo', instructions: [
        SetRegisterOp(registerName: 'x', value: 1),
        // Reading an unmounted VFS path throws inside the VM.
        ReadFileOp(vfsPath: '/nowhere/missing.txt', outputVar: 'r0'),
        HaltOp(),
      ]);

      final state = await runtime.executeProgram(program);
      expect(state.status, equals(RuntimeStatus.error));
      expect(state.errorDetails, contains('VASTER VM TRAP'));
      expect(state.errorDetails, contains('pc       : 1'));
      expect(state.errorDetails, contains('opcode   : read_file'));
      expect(state.errorDetails, contains('x = 1'));
    });
  });
}
