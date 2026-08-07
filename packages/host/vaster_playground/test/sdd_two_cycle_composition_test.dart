import 'package:test/test.dart';
import 'package:vaster_ast/vaster_ast.dart';
import 'package:vaster_compiler/vaster_compiler.dart';
import 'package:vaster_domain/vaster_domain.dart';
import 'package:vaster_model_fake/vaster_model_fake.dart';
import 'package:vaster_vm/vaster_vm.dart';

/// Backlog #6's failure mode: two SDD cycles in one pipeline used to
/// clobber each other's global binding names (spec/plan/review) —
/// last-write-wins. Under [BindingScope], both cycles keep their artifacts
/// and verdicts.
void main() {
  test('two scoped SDD cycles compose without collisions', () async {
    const architect = AgentRole(
      roleId: 'architect',
      name: 'Architect',
      title: 'Architect',
      instruction: 'You write specs and plans.',
    );
    const reviewer = AgentRole(
      roleId: 'reviewer',
      name: 'Reviewer',
      title: 'Reviewer',
      instruction: 'You review artifacts.',
    );

    VasterNode cycle(String goal) => Sequence([
      Specify(goal: Template.text(goal), agent: architect),
      const Plan(agent: architect),
      const Review(agent: reviewer),
    ]);

    final pipeline = Pipeline(
      name: 'two_cycles',
      roles: const [architect, reviewer],
      mounts: const [StorageMount(mountPrefix: '/workspace')],
      children: [
        BindingScope(namespace: 'auth', child: cycle('Build the auth flow.')),
        BindingScope(namespace: 'billing', child: cycle('Build the billing flow.')),
      ],
    );

    final result = const BasicWorkflowCompiler().compileWithDiagnostics(pipeline);
    expect(result.diagnostics.where((d) => d.severity == CompileSeverity.error), isEmpty);

    final vm = await VasterVMEngine.bootstrap(config: VMConfig(defaultModel: FakeVasterModel()));
    final runtime = VasterRuntime(
      vm: vm,
      policy: ExecutionPolicy.unlimited,
      budget: ExecutionBudget.unlimited(),
      scheduler: BasicVasterScheduler(taskQueue: PriorityTaskQueue()),
    );

    final state = await runtime.executeProgram(result.program);
    expect(state.status, equals(RuntimeStatus.halted));

    // Both cycles' bindings coexist — nothing clobbered.
    for (final name in [
      'auth_spec',
      'auth_plan',
      'auth_review',
      'auth_review_verdict',
      'billing_spec',
      'billing_plan',
      'billing_review',
      'billing_review_verdict',
    ]) {
      expect(state.registers.containsKey(name), isTrue, reason: 'missing binding $name');
    }
    expect(state.registers['auth_spec'], isNot(equals(state.registers['billing_spec'])));

    // Artifacts namespaced per cycle.
    final fs = vm.fileSystemManager.resolveFileSystem('/workspace/x');
    expect(await fs.readText('/workspace/auth_spec.md'), contains('auth'));
    expect(await fs.readText('/workspace/billing_spec.md'), contains('billing'));
    expect(await fs.readText('/workspace/auth_review.md'), isNotEmpty);
    expect(await fs.readText('/workspace/billing_review.md'), isNotEmpty);
  });
}
