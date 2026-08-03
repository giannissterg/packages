import 'package:test/test.dart';
import 'package:vaster_ast/vaster_ast.dart';
import 'package:vaster_compiler/vaster_compiler.dart';
import 'package:vaster_domain/vaster_domain.dart';
import 'package:vaster_model_fake/vaster_model_fake.dart';
import 'package:vaster_playground/vaster_playground.dart';
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
      expect(
        roleIds,
        containsAll([
          'architect',
          'tech_lead',
          'backend_dev',
          'frontend_dev',
          'security_auditor',
          'qa_engineer',
          'tech_writer',
        ]),
      );
    });

    test('emits DispatchParallelTasksOp for parallel backend+frontend build', () {
      final parallelOps = program.instructions.whereType<DispatchParallelTasksOp>().toList();
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

    test('Provider<T> scoping leaves no ISA footprint', () {
      // ProviderNode emits zero instructions itself; only its children do.
      // Confirm the instruction list has no dedicated "provide" opcode.
      final opcodes = program.instructions.map((i) => i.toJson()['opcode'] as String).toList();
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
    test(
      'ProvisionAgentTeamComponent reads ProjectConfig and includes project name in instructions',
      () {
        const cfg = ProjectConfig(projectName: 'MyApp', language: 'Go');
        const component = ProvisionAgentTeamComponent();
        final context = BuildContext(
          pipelineSpec: PipelineSpec(name: 'test'),
          typedValues: {ProjectConfig: cfg},
        );

        final expanded = component.build(context);
        final roles = (expanded as Pipeline).children.whereType<Agent>().toList();

        expect(roles, hasLength(7));
        expect(roles.first.role.instruction, contains('MyApp'));
        expect(roles.first.role.instruction, contains('Go'));
      },
    );

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
      final tx = expanded as Transaction;
      final taskNode = tx.children.whereType<Task>().first;
      expect(taskNode.prompt, contains('OWASP Top 10'));
      expect(taskNode.prompt, contains('5'));
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
      final tx = expanded as Transaction;
      final taskNode = tx.children.whereType<Task>().first;
      expect(taskNode.prompt, isNot(contains('OWASP Top 10')));
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
      final tx = expanded as Transaction;
      final taskNode = tx.children.whereType<Task>().first;
      expect(taskNode.prompt, contains('95%'));
      expect(taskNode.prompt, contains('NexusAPI'));
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
      final runtime = VasterRuntime(
        vm: vm,
        policy: ExecutionPolicy.unlimited,
        budget: ExecutionBudget.unlimited(),
        scheduler: BasicVasterScheduler(taskQueue: PriorityTaskQueue()),
      );
      final program = compiler.compile(nexusApiPipeline);
      var state = await runtime.executeProgram(program);
      if (state.status == RuntimeStatus.pausedForHuman) {
        state = await runtime.resumeWithHumanResponse(
          HumanInteractionResponse.approve(requestId: 'nexus_release_approval'),
        );
      }

      expect(state.status, equals(RuntimeStatus.halted));
      expect(state.registers.containsKey('__output__'), isTrue);
      expect(state.registers['__output__'], contains('# Nexus API — Final Delivery Report'));

      // Interpolation is real: written artifacts contain the agents' actual
      // responses, never a literal ${...} placeholder.
      final archDoc = await vm.fileSystemManager
          .resolveFileSystem('/workspace/docs/architecture.md')
          .readText('/workspace/docs/architecture.md');
      expect(archDoc, isNot(contains(r'${')),
          reason: 'placeholders must resolve, not be written verbatim');
      expect(archDoc, isNotEmpty);
      final auditDoc = await vm.fileSystemManager
          .resolveFileSystem('/workspace/reports/security_audit.md')
          .readText('/workspace/reports/security_audit.md');
      expect(auditDoc, contains('Security Audit'));
      expect(auditDoc, isNot(contains(r'${')));

      await vm.shutdown();
    });

    test('runPlayground() helper executes pipeline end-to-end', () async {
      await runPlayground();
    });
  });

  group('Custom Multi-Agent Pipeline — Research & Review', () {
    test('compiles and executes a 3-agent pipeline with parallel tasks and HITL', () async {
      // ── Build a custom 3-agent pipeline: Researcher, Reviewer, Approver ──
      final pipeline = Pipeline(
        spec: const PipelineSpec(name: 'research_review_pipeline'),
        children: [
          // Provision 3 agents
          Agent(
            role: AgentRole(
              roleId: 'researcher',
              name: 'Researcher',
              title: 'Research Agent',
              instruction: 'You research topics and produce concise summaries.',
            ),
          ),
          Agent(
            role: AgentRole(
              roleId: 'reviewer_a',
              name: 'Reviewer A',
              title: 'Senior Reviewer',
              instruction: 'You review research summaries for accuracy and completeness.',
            ),
          ),
          Agent(
            role: AgentRole(
              roleId: 'reviewer_b',
              name: 'Reviewer B',
              title: 'Staff Reviewer',
              instruction: 'You review research summaries for clarity and structure.',
            ),
          ),
          // Write a topic brief to VFS
          WriteFile(
            path: '/workspace/topic.txt',
            content: 'Topic: Evaluate the trade-offs between microservices and monolithic architecture.',
          ),
          // Researcher reads the brief and produces a summary
          ReadFile(path: '/workspace/topic.txt'),
          Task(
            agentId: 'researcher',
            prompt: 'Research the following topic and produce a summary:\n\n\${topic_brief}',
          ),
          WriteFile(path: '/workspace/research.md', content: '\${research_summary}'),
          // Two reviewers review in parallel
          ParallelTasks(
            entries: [
              ParallelTaskEntry(
                agentId: 'reviewer_a',
                prompt: 'Review this research summary for accuracy:\n\n\${research_summary}',
                output: 'review_a',
              ),
              ParallelTaskEntry(
                agentId: 'reviewer_b',
                prompt: 'Review this research summary for clarity:\n\n\${research_summary}',
                output: 'review_b',
              ),
            ],
          ),
          // Human approval gate before finalizing
          ApprovalGate(
            requestId: 'research_approval',
            prompt: 'Approve the research summary and reviews?',
            onApprove: [
              WriteFile(path: '/workspace/final_report.md', content: 'Approved!\n\n\${research_summary}'),
            ],
          ),
        ],
      );

      // ── Compile ──
      final program = compiler.compile(pipeline);
      expect(program.programName, equals('research_review_pipeline'));
      expect(program.instructions, isNotEmpty);
      expect(program.instructions.last, isA<HaltOp>());

      // Verify 3 CreateAgentOp instructions
      final createOps = program.instructions.whereType<CreateAgentOp>().toList();
      expect(createOps, hasLength(3));
      final roleIds = createOps.map((o) => o.descriptor.agentId).toSet();
      expect(roleIds, containsAll(['researcher', 'reviewer_a', 'reviewer_b']));

      // Verify parallel dispatch
      final parallelOps = program.instructions.whereType<DispatchParallelTasksOp>().toList();
      expect(parallelOps, hasLength(1));
      expect(parallelOps.first.dispatches, hasLength(2));

      // ── Execute ──
      final fakeModel = FakeVasterModel(
        defaultResponseText: 'Task completed successfully.',
      );
      final vm = await VasterVMEngine.bootstrap(
        config: VMConfig(defaultModel: fakeModel, rootMountPath: '/workspace'),
      );
      final runtime = VasterRuntime(
        vm: vm,
        policy: ExecutionPolicy.unlimited,
        budget: ExecutionBudget.unlimited(),
        scheduler: BasicVasterScheduler(taskQueue: PriorityTaskQueue()),
      );

      var state = await runtime.executeProgram(program);
      expect(state.status, equals(RuntimeStatus.pausedForHuman));

      // Approve the research
      state = await runtime.resumeWithHumanResponse(
        HumanInteractionResponse.approve(requestId: 'research_approval'),
      );

      expect(state.status, equals(RuntimeStatus.halted));

      // Verify final report was written to VFS
      final report = await vm.fileSystemManager
          .resolveFileSystem('/workspace/final_report.md')
          .readText('/workspace/final_report.md');
      expect(report, contains('Approved!'));

      await vm.shutdown();
    });
  });
}
