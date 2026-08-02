import 'package:test/test.dart';
import 'package:vaster_ast/vaster_ast.dart';
import 'package:vaster_compiler/vaster_compiler.dart';
import 'package:vaster_domain/vaster_domain.dart';
import 'package:vaster_instruction/vaster_instruction.dart';
import 'package:vaster_model_fake/vaster_model_fake.dart';
import 'package:vaster_policy/vaster_policy.dart';
import 'package:vaster_playground/vaster_playground.dart';
import 'package:vaster_runtime/vaster_runtime.dart';
import 'package:vaster_vm/vaster_vm.dart';

void main() {
  const compiler = BasicWorkflowCompiler();

  group('Nexus API Pipeline — Compilation', () {
    late VasterProgram program;

    setUpAll(() {
      program = compiler.compile(nexusApiPipeline);
    });

    test('compiles to a non-empty VasterProgram', () {
      expect(program.programName, equals('nexus_api_delivery_pipeline'));
      expect(program.instructions, isNotEmpty);
      expect(program.instructions.last, isA<HaltOp>());
    });

    test('emits MountFsOp for /workspace storage', () {
      final mountOps = program.instructions.whereType<MountFsOp>().toList();
      expect(mountOps, isNotEmpty);
      expect(mountOps.first.mountPrefix, equals('/workspace'));
    });

    test('emits 7 CreateAgentOp instructions (one per role)', () {
      final createOps = program.instructions.whereType<CreateAgentOp>().toList();
      expect(createOps, hasLength(7));
      final roleIds = createOps.map((o) => o.descriptor.agentId).toSet();
      expect(roleIds, containsAll([
        'architect', 'tech_lead', 'backend_dev', 'frontend_dev',
        'security_auditor', 'qa_engineer', 'tech_writer',
      ]));
    });

    test('emits DispatchParallelTasksOp for parallel backend+frontend build', () {
      final parallelOps =
          program.instructions.whereType<DispatchParallelTasksOp>().toList();
      expect(parallelOps, isNotEmpty);
      final dispatches = parallelOps.first.dispatches;
      expect(dispatches, hasLength(2));
      final agentIds = dispatches.map((d) => d.agentId).toSet();
      expect(agentIds, containsAll(['backend_dev', 'frontend_dev']));
    });

    test('emits BeginTransactionOp / CommitOp pairs for transactional steps', () {
      final begins = program.instructions.whereType<BeginTransactionOp>().length;
      final commits = program.instructions.whereType<CommitOp>().length;
      expect(begins, equals(commits));
      expect(begins, greaterThan(0));
    });

    test('ProviderNode<T> scoping leaves no ISA footprint', () {
      // ProviderNode emits zero instructions itself; only its children do.
      // Confirm the instruction list has no dedicated "provide" opcode.
      final opcodes = program.instructions
          .map((i) => i.toJson()['opcode'] as String)
          .toList();
      expect(opcodes.any((op) => op.contains('provide')), isFalse);
    });

    test('program is JSON-serializable and round-trips correctly', () {
      final json = program.toJson();
      final restored = VasterProgram.fromJson(json);
      expect(restored.programName, equals(program.programName));
      expect(restored.instructions, hasLength(program.instructions.length));
    });
  });

  group('Nexus API Pipeline — Typed Context Injection', () {
    test('ProvisionAgentTeamComponent reads ProjectConfig and includes project name in instructions', () {
      const cfg = ProjectConfig(projectName: 'MyApp', language: 'Go');
      const component = ProvisionAgentTeamComponent();
      final context = BuildContext(
        pipelineSpec: PipelineSpec(name: 'test'),
        typedValues: {ProjectConfig: cfg},
      );

      final expanded = component.build(context);
      final roles = (expanded as PipelineNode)
          .bodyNodes
          .whereType<DefineRoleNode>()
          .toList();

      expect(roles, hasLength(7));
      expect(roles.first.role.instruction, contains('MyApp'));
      expect(roles.first.role.instruction, contains('Go'));
    });

    test('SecurityAuditComponent reads SecurityPolicy and includes OWASP clause when required', () {
      const policy = SecurityPolicy(requireOWASPAudit: true, maxCvssScore: 5);
      const component = SecurityAuditComponent(
        backendPath: '/src/main.dart',
        architecturePath: '/docs/arch.md',
      );
      final context = BuildContext(
        pipelineSpec: PipelineSpec(name: 'test'),
        typedValues: {
          ProjectConfig: const ProjectConfig(projectName: 'Test', language: 'Dart'),
          SecurityPolicy: policy,
        },
      );

      final expanded = component.build(context);
      final tx = expanded as StepTransactionNode;
      final taskNode = tx.bodyNodes.whereType<PerformTaskNode>().first;
      expect(taskNode.task.promptText, contains('OWASP Top 10'));
      expect(taskNode.task.promptText, contains('5'));
    });

    test('SecurityAuditComponent omits OWASP clause when not required', () {
      const policy = SecurityPolicy(requireOWASPAudit: false);
      const component = SecurityAuditComponent(
        backendPath: '/src/main.dart',
        architecturePath: '/docs/arch.md',
      );
      final context = BuildContext(
        pipelineSpec: PipelineSpec(name: 'test'),
        typedValues: {
          ProjectConfig: const ProjectConfig(projectName: 'Test', language: 'Dart'),
          SecurityPolicy: policy,
        },
      );

      final expanded = component.build(context);
      final tx = expanded as StepTransactionNode;
      final taskNode = tx.bodyNodes.whereType<PerformTaskNode>().first;
      expect(taskNode.task.promptText, isNot(contains('OWASP Top 10')));
    });

    test('TestSuiteComponent reads both ProjectConfig and QualityGate', () {
      const project = ProjectConfig(projectName: 'NexusAPI', language: 'Dart');
      const gate = QualityGate(minTestCoverage: 95, enforceDocCoverage: true);
      const component = TestSuiteComponent();
      final context = BuildContext(
        pipelineSpec: PipelineSpec(name: 'test'),
        typedValues: {ProjectConfig: project, QualityGate: gate},
      );

      final expanded = component.build(context);
      final tx = expanded as StepTransactionNode;
      final taskNode = tx.bodyNodes.whereType<PerformTaskNode>().first;
      expect(taskNode.task.promptText, contains('95%'));
      expect(taskNode.task.promptText, contains('NexusAPI'));
    });
  });

  group('Nexus API Pipeline — E2E Execution', () {
    test('executes full pipeline and produces delivery_report', () async {
      final fakeModel = FakeVasterModel(
        defaultResponseText: 'Agent task completed.',
        responseMap: agentResponseMap,
      );

      final vm = await VasterVMEngine.bootstrap(
        config: VMConfig(defaultModel: fakeModel, rootMountPath: '/workspace'),
      );
      final runtime = VasterRuntime(vm: vm, policy: ExecutionPolicy.unlimited);
      final program = compiler.compile(nexusApiPipeline);
      var state = await runtime.executeProgram(program);
      if (state.status == RuntimeStatus.pausedForHuman) {
        state = await runtime.resumeWithHumanResponse(
          HumanInteractionResponse.approve(requestId: 'nexus_release_approval'),
        );
      }

      expect(state.status, equals(RuntimeStatus.halted));
      expect(state.registers.containsKey('delivery_report'), isTrue);
      expect(state.registers['delivery_report'], contains('Agent task completed'));

      // Verify VFS artefacts were written
      expect(state.registers.containsKey('architecture_doc'), isTrue);
      expect(state.registers.containsKey('security_report'), isTrue);
      expect(state.registers.containsKey('test_suite'), isTrue);
      expect(state.registers.containsKey('api_documentation'), isTrue);

      await vm.shutdown();
    });

    test('runPlayground() helper executes pipeline end-to-end', () async {
      await runPlayground();
    });
  });
}
