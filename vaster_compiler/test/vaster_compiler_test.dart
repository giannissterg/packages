import 'package:test/test.dart';
import 'package:vaster_ast/vaster_ast.dart';
import 'package:vaster_compiler/vaster_compiler.dart';
import 'package:vaster_domain/vaster_domain.dart';
import 'package:vaster_instruction/vaster_instruction.dart';
import 'package:vaster_model_fake/vaster_model_fake.dart';
import 'package:vaster_policy/vaster_policy.dart';
import 'package:vaster_runtime/vaster_runtime.dart';
import 'package:vaster_vm/vaster_vm.dart';

// ── Test types ─────────────────────────────────────────────────────────────────

class ReviewPolicy {
  final bool strictMode;
  final int maxIssues;
  const ReviewPolicy({required this.strictMode, this.maxIssues = 10});
}

// ── ComposableNodes ────────────────────────────────────────────────────────────

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

/// ComposableNode that reads ReviewPolicy from context.
class PolicyAwareReviewComponent extends ComposableNode {
  final String filePath;
  final String auditorRoleId;

  const PolicyAwareReviewComponent({
    required this.filePath,
    required this.auditorRoleId,
  });

  @override
  WorkflowAstNode build(BuildContext context) {
    final policy = context.read<ReviewPolicy>();
    final modeLabel = policy.strictMode ? '[STRICT]' : '[LENIENT]';
    return PerformTaskNode(
      agentRoleId: auditorRoleId,
      task: TaskDefinition(
        taskId: 'policy_review',
        promptText: '$modeLabel Review $filePath (max issues: ${policy.maxIssues})',
        outputVariable: 'policy_review_result',
      ),
    );
  }
}

// ── Tests ─────────────────────────────────────────────────────────────────────

void main() {
  const compiler = BasicWorkflowCompiler();

  group('BasicWorkflowCompiler - exhaustive switch', () {
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
      expect(program.instructions[0], isA<MountFsOp>());
      expect(program.instructions[1], isA<CreateAgentOp>());
      expect(program.instructions[2], isA<CreateSessionOp>());
      expect(program.instructions[3], isA<SetSessionOp>());
      expect(program.instructions[4], isA<DispatchAgentTaskOp>());
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

      // BootstrapStorageComponent -> StepTransactionNode -> Begin, Mount, Write, Commit
      expect(program.instructions[0], isA<BeginTransactionOp>());
      expect(program.instructions[1], isA<MountFsOp>());
      expect(program.instructions[2], isA<WriteFileOp>());
      expect(program.instructions[3], isA<CommitOp>());
      expect(program.instructions[4], isA<PromptOp>());
      expect(program.instructions.last, isA<HaltOp>());
    });

    test('compiles SelectModelNode into SelectModelOp ISA opcode', () {
      const spec = PipelineSpec(name: 'select_model_pipeline');
      const descriptor = ModelDescriptor.geminiCli(modelId: 'gemini-2.5-flash');
      final pipeline = PipelineNode(
        spec: spec,
        bodyNodes: const [
          SelectModelNode(model: descriptor),
        ],
      );

      final program = compiler.compile(pipeline);
      final selectOps = program.instructions.whereType<SelectModelOp>().toList();

      expect(selectOps, hasLength(1));
      expect(selectOps.first.descriptor, equals(descriptor));
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
  });

  group('BasicWorkflowCompiler - ProviderNode<T> context injection', () {
    test('ProviderNode injects typed value into BuildContext for ComposableNode children', () {
      const policy = ReviewPolicy(strictMode: true, maxIssues: 5);

      const pipeline = PipelineNode(
        spec: PipelineSpec(name: 'provider_pipeline'),
        bodyNodes: [
          ProviderNode<ReviewPolicy>(
            value: policy,
            children: [
              PolicyAwareReviewComponent(
                filePath: '/src/auth.dart',
                auditorRoleId: 'auditor',
              ),
            ],
          ),
        ],
      );

      final program = compiler.compile(pipeline);

      // ProviderNode emits no ISA instructions; only the inner PerformTaskNode does
      final dispatchOp = program.instructions
          .whereType<DispatchAgentTaskOp>()
          .first;

      expect(dispatchOp.taskPrompt, contains('[STRICT]'));
      expect(dispatchOp.taskPrompt, contains('max issues: 5'));
      expect(dispatchOp.agentId, equals('auditor'));
    });

    test('ProviderNode scopes injected value only to its children', () {
      const policy = ReviewPolicy(strictMode: false, maxIssues: 20);

      // ComposableNode outside ProviderNode should NOT see the typed value
      const pipeline = PipelineNode(
        spec: PipelineSpec(name: 'scoped_provider_pipeline'),
        bodyNodes: [
          ProviderNode<ReviewPolicy>(
            value: policy,
            children: [
              PolicyAwareReviewComponent(
                filePath: '/src/db.dart',
                auditorRoleId: 'db_auditor',
              ),
            ],
          ),
          PromptModelNode(promptText: 'End of pipeline', outputVariable: 'end'),
        ],
      );

      final program = compiler.compile(pipeline);

      final dispatchOps = program.instructions.whereType<DispatchAgentTaskOp>().toList();
      expect(dispatchOps, hasLength(1));
      expect(dispatchOps.first.taskPrompt, contains('[LENIENT]'));
    });
  });

  group('BasicWorkflowCompiler - E2E execution on VasterRuntime', () {
    test('compiles VasterProgram and executes successfully on VasterRuntime', () async {
      final fakeModel = FakeVasterModel(defaultResponseText: 'Pipeline complete.');
      final vm = await VasterVMEngine.bootstrap(
        config: VMConfig(defaultModel: fakeModel, rootMountPath: '/mem'),
      );
      final runtime = VasterRuntime(vm: vm, policy: ExecutionPolicy.unlimited);

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
