import 'package:test/test.dart';
import 'package:vaster_ast/vaster_ast.dart';
import 'package:vaster_compiler/vaster_compiler.dart';
import 'package:vaster_domain/vaster_domain.dart';
import 'package:vaster_model_fake/vaster_model_fake.dart';
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
  VasterNode build(BuildContext context) {
    return Transaction(
      children: [
        Mount(mount: StorageMount(mountPrefix: prefix)),
        WriteFile(path: Template.text('$prefix/readme.md'), content: Template.text('Pipeline: ${context.pipelineSpec.name}')),
      ],
    );
  }
}

/// ComposableNode that reads ReviewPolicy from context.
class PolicyAwareReviewComponent extends ComposableNode {
  final String filePath;
  final String auditorRoleId;

  const PolicyAwareReviewComponent({required this.filePath, required this.auditorRoleId});

  @override
  VasterNode build(BuildContext context) {
    final policy = context.read<ReviewPolicy>();
    final modeLabel = policy.strictMode ? '[STRICT]' : '[LENIENT]';
    return Task(
      agentId: auditorRoleId,
      prompt: Template.text('$modeLabel Review $filePath (max issues: ${policy.maxIssues})'),
    );
  }
}

// ── Tests ─────────────────────────────────────────────────────────────────────

void main() {
  const compiler = BasicWorkflowCompiler();

  group('BasicWorkflowCompiler - exhaustive switch', () {
    test('compiles Pipeline into VasterProgram with correct ISA opcodes', () {
      const pipeline = Pipeline(
        spec: PipelineSpec(name: 'auth_pipeline', rootStoragePath: '/workspace'),
        children: [
          Mount(mount: StorageMount(mountPrefix: '/workspace')),
          Agent(
            role: AgentRole(
              roleId: 'architect',
              name: 'Architect',
              title: 'Senior Engineer',
              instruction: 'Design the auth system.',
            ),
          ),
          Task(
            agentId: 'architect',
            prompt: Template.text('Design the Auth Service API.'),
          ),
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
      const pipeline = Pipeline(
        spec: PipelineSpec(name: 'composable_pipeline'),
        children: [
          BootstrapStorageComponent(prefix: '/mem'),
          Prompt(Template.text('Summarize')),
        ],
      );

      final program = compiler.compile(pipeline);

      // BootstrapStorageComponent -> Transaction -> Begin, Mount, Write, Commit
      expect(program.instructions[0], isA<BeginTransactionOp>());
      expect(program.instructions[1], isA<MountFsOp>());
      expect(program.instructions[2], isA<WriteFileOp>());
      expect(program.instructions[3], isA<CommitOp>());
      expect(program.instructions[4], isA<PromptOp>());
      expect(program.instructions.last, isA<HaltOp>());
    });

    test('compiles SelectModel into SelectModelOp ISA opcode', () {
      const spec = PipelineSpec(name: 'select_model_pipeline');
      const descriptor = ModelDescriptor.geminiCli(modelId: 'gemini-2.5-flash');
      final pipeline = Pipeline(
        spec: spec,
        children: const [SelectModel(model: descriptor)],
      );

      final program = compiler.compile(pipeline);
      final selectOps = program.instructions.whereType<SelectModelOp>().toList();

      expect(selectOps, hasLength(1));
      expect(selectOps.first.descriptor, equals(descriptor));
    });

    test('compiles SelectModel fallbacks into the op\'s chain (REL-P3)', () {
      const primary = ModelDescriptor.geminiCli(modelId: 'gemini-2.5-pro');
      const fb1 = ModelDescriptor.geminiCli(modelId: 'gemini-2.5-flash');
      const fb2 = ModelDescriptor.fake(modelId: 'local');
      final pipeline = Pipeline(
        spec: const PipelineSpec(name: 'fallback_chain_pipeline'),
        children: const [
          SelectModel(model: primary, fallbacks: [fb1, fb2]),
        ],
      );

      final program = compiler.compile(pipeline);
      final op = program.instructions.whereType<SelectModelOp>().single;

      // The declared chain compiles in ORDER — the runtime falls through
      // first-to-last on model-kind failure.
      expect(op.descriptor, equals(primary));
      expect(op.fallbacks, equals(const [fb1, fb2]));
    });

    test('compiles Transaction with BeginTransaction / Commit boundary', () {
      const pipeline = Pipeline(
        spec: PipelineSpec(name: 'tx_pipeline'),
        children: [
          Transaction(
            children: [WriteFile(path: Template.text('/mem/spec.md'), content: Template.text('v1'))],
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

  group('BasicWorkflowCompiler - Provider<T> context injection', () {
    test('Provider injects typed value into BuildContext for ComposableNode children', () {
      const policy = ReviewPolicy(strictMode: true, maxIssues: 5);

      const pipeline = Pipeline(
        spec: PipelineSpec(name: 'provider_pipeline'),
        children: [
          Provider<ReviewPolicy>(
            value: policy,
            children: [
              PolicyAwareReviewComponent(filePath: '/src/auth.dart', auditorRoleId: 'auditor'),
            ],
          ),
        ],
      );

      final program = compiler.compile(pipeline);

      // Provider emits no ISA instructions; only the inner Task does
      final dispatchOp = program.instructions.whereType<DispatchAgentTaskOp>().first;

      expect(dispatchOp.taskPrompt, contains('[STRICT]'));
      expect(dispatchOp.taskPrompt, contains('max issues: 5'));
      expect(dispatchOp.agentId, equals('auditor'));
    });

    test('Provider scopes injected value only to its children', () {
      const policy = ReviewPolicy(strictMode: false, maxIssues: 20);

      // ComposableNode outside Provider should NOT see the typed value
      const pipeline = Pipeline(
        spec: PipelineSpec(name: 'scoped_provider_pipeline'),
        children: [
          Provider<ReviewPolicy>(
            value: policy,
            children: [
              PolicyAwareReviewComponent(filePath: '/src/db.dart', auditorRoleId: 'db_auditor'),
            ],
          ),
          Prompt(Template.text('End of pipeline')),
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
      final runtime = VasterRuntime(
        vm: vm,
        policy: ExecutionPolicy.unlimited,
        budget: ExecutionBudget.unlimited(),
        scheduler: BasicVasterScheduler(taskQueue: PriorityTaskQueue()),
      );

      const pipeline = Pipeline(
        spec: PipelineSpec(name: 'e2e_pipeline'),
        result: Binding('analysis'),
        children: [
          Mount(mount: StorageMount(mountPrefix: '/mem')),
          WriteFile(path: Template.text('/mem/brief.txt'), content: Template.text('Build a REST API')),
          ReadFile(path: Template.text('/mem/brief.txt')),
          Prompt(Template.text('Analyze the brief'), output: Binding('analysis')),
        ],
      );

      final program = compiler.compile(pipeline);
      // The result is header metadata now — no ConcatRegisterOp/__output__.
      expect(program.resultBinding, equals('analysis'));
      expect(
        program.instructions
            .whereType<ConcatRegisterOp>()
            .any((op) => op.targetVar == '__output__'),
        isFalse,
      );

      final state = await runtime.executeProgram(program);

      expect(state.status, equals(RuntimeStatus.halted));
      expect(state.registers['analysis'], contains('Analyze the brief'));

      await vm.shutdown();
    });
  });
}
