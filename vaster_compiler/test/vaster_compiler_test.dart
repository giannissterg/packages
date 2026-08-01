import 'package:test/test.dart';
import 'package:vaster_ast/vaster_ast.dart';
import 'package:vaster_compiler/vaster_compiler.dart';
import 'package:vaster_domain/vaster_domain.dart';
import 'package:vaster_instruction/vaster_instruction.dart';
import 'package:vaster_model_fake/vaster_model_fake.dart';
import 'package:vaster_runtime/vaster_runtime.dart';
import 'package:vaster_vm/vaster_vm.dart';

// Custom ComposableNode to verify recursive compiler expansion
class BootstrapStorageComponent extends ComposableNode {
  final String prefix;
  const BootstrapStorageComponent({required this.prefix});

  @override
  WorkflowAstNode build(BuildContext context) {
    return StepTransactionNode(bodyNodes: [
      MountStorageNode(mount: StorageMount(mountPrefix: prefix)),
      WriteDocumentNode(
        path: '$prefix/readme.md',
        content: 'Pipeline: ${context.pipelineSpec.name}',
      ),
    ]);
  }
}

void main() {
  group('BasicWorkflowCompiler', () {
    const compiler = BasicWorkflowCompiler();

    test('compiles PipelineNode into VasterProgram with correct ISA opcodes', () {
      const pipeline = PipelineNode(
        spec: PipelineSpec(name: 'auth_pipeline', rootStoragePath: '/workspace'),
        bodyNodes: [
          MountStorageNode(mount: StorageMount(mountPrefix: '/workspace')),
          DefineRoleNode(
            role: AgentRole(
              roleId: 'architect',
              name: 'Architect',
              title: 'Senior Engineer',
              instruction: 'Design the auth system.',
            ),
          ),
          PerformTaskNode(
            agentRoleId: 'architect',
            task: TaskDefinition(
              taskId: 'design_auth',
              promptText: 'Design the Auth Service API.',
              outputVariable: 'design_output',
            ),
          ),
          OutputNode(outputVariable: 'design_output'),
        ],
      );

      final program = compiler.compile(pipeline);

      expect(program.programName, equals('auth_pipeline'));
      expect(program.instructions.first, isA<MountFsOp>());
      expect(program.instructions[1], isA<CreateAgentOp>());
      expect(program.instructions[2], isA<DispatchAgentTaskOp>());
      expect(program.instructions.last, isA<HaltOp>());
    });

    test('expands ComposableNode recursively during compilation', () {
      const pipeline = PipelineNode(
        spec: PipelineSpec(name: 'composable_pipeline'),
        bodyNodes: [
          BootstrapStorageComponent(prefix: '/mem'),
          PromptModelNode(promptText: 'Summarize', outputVariable: 'summary'),
        ],
      );

      final program = compiler.compile(pipeline);

      // BootstrapStorageComponent expands to: BeginTransaction, MountFsOp, WriteFileOp, CommitOp
      expect(program.instructions[0], isA<BeginTransactionOp>());
      expect(program.instructions[1], isA<MountFsOp>());
      expect(program.instructions[2], isA<WriteFileOp>());
      expect(program.instructions[3], isA<CommitOp>());
      expect(program.instructions[4], isA<PromptOp>());
      expect(program.instructions.last, isA<HaltOp>());
    });

    test('compiles StepTransactionNode with BeginTransaction / Commit boundary', () {
      const pipeline = PipelineNode(
        spec: PipelineSpec(name: 'tx_pipeline'),
        bodyNodes: [
          StepTransactionNode(
            bodyNodes: [
              WriteDocumentNode(path: '/mem/spec.md', content: 'v1'),
            ],
          ),
        ],
      );

      final program = compiler.compile(pipeline);

      expect(program.instructions[0], isA<BeginTransactionOp>());
      expect(program.instructions[1], isA<WriteFileOp>());
      expect(program.instructions[2], isA<CommitOp>());
      expect(program.instructions.last, isA<HaltOp>());
    });

    test('compiles VasterProgram and executes successfully on VasterRuntime', () async {
      final fakeModel = FakeVasterModel(defaultResponseText: 'Pipeline complete.');
      final vm = await VasterVMEngine.bootstrap(
        config: VMConfig(defaultModel: fakeModel, rootMountPath: '/mem'),
      );
      final runtime = VasterRuntime(vm: vm);

      const pipeline = PipelineNode(
        spec: PipelineSpec(name: 'e2e_pipeline'),
        bodyNodes: [
          MountStorageNode(mount: StorageMount(mountPrefix: '/mem')),
          WriteDocumentNode(path: '/mem/brief.txt', content: 'Build a REST API'),
          ReadDocumentNode(path: '/mem/brief.txt', outputVariable: 'brief'),
          PromptModelNode(promptText: 'Analyze the brief', outputVariable: 'analysis'),
          OutputNode(outputVariable: 'analysis'),
        ],
      );

      final program = compiler.compile(pipeline);
      final state = await runtime.executeProgram(program);

      expect(state.status, equals(RuntimeStatus.halted));
      expect(state.registers['brief'], equals('Build a REST API'));
      expect(state.registers['analysis'], contains('Pipeline complete.'));

      await vm.shutdown();
    });
  });
}
