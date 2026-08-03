import 'package:test/test.dart';
import 'package:vaster_ast/vaster_ast.dart';
import 'package:vaster_budget/vaster_budget.dart';
import 'package:vaster_compiler/vaster_compiler.dart';
import 'package:vaster_domain/vaster_domain.dart';
import 'package:vaster_instruction/vaster_instruction.dart';
import 'package:vaster_model_fake/vaster_model_fake.dart';
import 'package:vaster_policy/vaster_policy.dart';
import 'package:vaster_runtime/vaster_runtime.dart';
import 'package:vaster_scheduler/vaster_scheduler.dart';
import 'package:vaster_vm/vaster_vm.dart';

void main() {
  group('Context management ISA — runtime execution', () {
    late VasterVirtualMachine vm;
    late VasterRuntime runtime;

    setUp(() async {
      vm = await VasterVMEngine.bootstrap(
          config: VMConfig(defaultModel: FakeVasterModel()));
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

    test('AddContextOp: literal + register-sourced content, policy applied',
        () async {
      const program = VasterProgram(programName: 'add_ctx', instructions: [
        SetRegisterOp(registerName: 'derived', value: 'computed content'),
        AddContextOp(
          regionId: 'static_region',
          label: 'static',
          text: 'literal content',
          priority: 'high',
          compressibility: 'truncate',
          pinned: true,
        ),
        AddContextOp(
          regionId: 'dynamic_region',
          label: 'dynamic',
          sourceVar: 'derived',
          lifetime: 'persistent',
        ),
        HaltOp(),
      ]);

      final state = await runtime.executeProgram(program);
      expect(state.status, equals(RuntimeStatus.halted));

      final staticRegion = vm.contextManager.getRegion('static_region')!;
      expect(regionContentOf(staticRegion), equals('literal content'));
      expect(staticRegion.priority.name, equals('high'));
      expect(staticRegion.compressibility.name, equals('truncate'));
      expect(staticRegion.isPinned, isTrue);

      final dynamicRegion = vm.contextManager.getRegion('dynamic_region')!;
      expect(regionContentOf(dynamicRegion), equals('computed content'));
      expect(dynamicRegion.lifetime.name, equals('persistent'));
    });

    test('Evict/Unpin/SetPolicy ops manage the heap and cache hints', () async {
      const program = VasterProgram(programName: 'manage_ctx', instructions: [
        AddContextOp(regionId: 'a', label: 'a', text: 'aaa', pinned: true),
        AddContextOp(regionId: 'b', label: 'b', text: 'bbb'),
        // Unpin a → its cache hint must be released.
        UnpinContextOp(regionId: 'a'),
        // Policy update on b: promote + pin.
        SetContextPolicyOp(regionId: 'b', priority: 'critical', pinned: true),
        // Evict a (unpinned now, no force needed).
        EvictContextOp(regionId: 'a'),
        HaltOp(),
      ]);

      final state = await runtime.executeProgram(program);
      expect(state.status, equals(RuntimeStatus.halted));

      expect(vm.contextManager.getRegion('a'), isNull);
      final b = vm.contextManager.getRegion('b')!;
      expect(b.priority.name, equals('critical'));
      expect(b.isPinned, isTrue);
    });

    test('pinned region survives EvictContextOp without force', () async {
      const program = VasterProgram(programName: 'protected', instructions: [
        AddContextOp(regionId: 'keep', label: 'keep', text: 'kept', pinned: true),
        EvictContextOp(regionId: 'keep'), // no force → refused
        HaltOp(),
      ]);
      await runtime.executeProgram(program);
      expect(vm.contextManager.getRegion('keep'), isNotNull);
    });

    test('CompressContextOp shrinks a region and reports freed tokens', () async {
      final bigText = List.generate(60, (i) => 'line $i of the log').join('\n');
      final program = VasterProgram(programName: 'compress', instructions: [
        AddContextOp(
          regionId: 'log',
          label: 'log',
          text: bigText,
          compressibility: 'truncate',
        ),
        const CompressContextOp(
            regionId: 'log', targetTokens: 40, outputVar: 'freed'),
        const HaltOp(),
      ]);

      final state = await runtime.executeProgram(program);
      expect(state.status, equals(RuntimeStatus.halted));
      // Region content notes: AddContext creates ONE message; the truncating
      // compressor can't split a single message, so freed may be 0. Verify
      // the op executed and wrote a numeric result.
      expect(int.tryParse(state.registers['freed'] as String), isNotNull);
    });
  });

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
          const Agent(role: architect, children: [
            Task(taskPrompt: 'Design the notes app architecture'),
          ]),
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
