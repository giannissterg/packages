import 'package:test/test.dart';
import 'package:vaster_ast/vaster_ast.dart';
import 'package:vaster_compiler/vaster_compiler.dart';
import 'package:vaster_domain/vaster_domain.dart';
import 'package:vaster_model_fake/vaster_model_fake.dart';
import 'package:vaster_vm/vaster_vm.dart';

/// Compiler → ISA → runtime E2E coverage for context-management AST nodes and
/// the program analyzer's context diagnostics.
///
/// ISA-level context-op behavior is tested in
/// `vaster_runtime/test/context_ops_runtime_test.dart` with hand-assembled
/// programs.
void main() {
  group('E2E smoke — compiled context-managed pipeline', () {
    test('AddContext -> Task -> CompressContext -> EvictContext + inspection',
        () async {
      final fakeModel = FakeVasterModel(defaultResponseText: 'Design done.');
      final vm = await VasterVMEngine.bootstrap(
          config: VMConfig(defaultModel: fakeModel));
      final runtime = VasterRuntime(
        vm: vm,
        policy: ExecutionPolicy.unlimited,
        budget: ExecutionBudget.unlimited(),
        scheduler: BasicVasterScheduler(taskQueue: PriorityTaskQueue()),
      );

      const architect = AgentRole(
        roleId: 'architect',
        name: 'Architect',
        title: 'Architect',
        instruction: 'Design.',
      );

      final pipeline = Pipeline(
        spec: const PipelineSpec(name: 'ctx_managed'),
        roles: const [architect],
        children: [
          const AddContext(
            regionId: 'project_brief',
            label: 'project brief',
            text: 'Build a notes application with sync.',
            priority: ContextPriority.high,
            pinned: true,
          ),
          const AddContext(
            regionId: 'meeting_log',
            label: 'meeting log',
            text: 'Long meeting transcript...',
            compressibility: ContextCompressibility.truncate,
          ),
          const Agent(
              role: architect,
              child: Task(prompt: 'Design the notes app architecture')),
          const CompressContext(targetTokens: 100000),
          const EvictContext(regionId: 'meeting_log'),
          const Output(),
        ],
      );

      // Compile with diagnostics: context ops produce info diagnostics at most.
      const compiler = BasicWorkflowCompiler();
      final result = compiler.compileWithDiagnostics(pipeline);
      expect(result.hasErrors, isFalse);

      final state = await runtime.executeProgram(result.program);
      expect(state.status, equals(RuntimeStatus.halted));

      // Inspection through the VM workspace facade.
      final report = vm.contextWorkspace.inspect();
      expect(report.rows.map((r) => r.id), contains('project_brief'));
      expect(report.rows.map((r) => r.id), isNot(contains('meeting_log')),
          reason: 'evicted by EvictContext');
      final brief =
          report.rows.firstWhere((r) => r.id == 'project_brief');
      expect(brief.isPinned, isTrue);
      expect(report.toPrettyString(), contains('project_brief'));

      await vm.shutdown();
    });

    test('analyzer emits info (not warning) for externally provisioned regions',
        () {
      const program = VasterProgram(programName: 'ext', instructions: [
        EvictContextOp(regionId: 'provisioned_by_host'),
        HaltOp(),
      ]);
      final diagnostics = const ProgramAnalyzer().analyze(program);
      final regionDiags =
          diagnostics.where((d) => d.code == 'ctx_unknown_region');
      expect(regionDiags, hasLength(1));
      expect(regionDiags.single.severity, equals(CompileSeverity.info));
    });
  });
}
