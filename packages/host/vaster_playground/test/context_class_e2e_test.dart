import 'package:test/test.dart';
import 'package:vaster_ast/vaster_ast.dart';
import 'package:vaster_compiler/vaster_compiler.dart';
import 'package:vaster_domain/vaster_domain.dart';
import 'package:vaster_model_fake/vaster_model_fake.dart';
import 'package:vaster_vm/vaster_vm.dart';

/// End-to-end: a pipeline declares context classes, the compiler carries them
/// in the program header, the runtime installs them, and the agent's model
/// request is laid out segment-by-segment.
void main() {
  test('declared classes shape the compiled request end to end', () async {
    const analyst = AgentRole(
      roleId: 'analyst',
      name: 'Analyst',
      title: 'Analyst',
      instruction: 'You analyze APIs carefully.',
    );

    const pipeline = Pipeline(
      name: 'context_class_e2e',
      roles: [analyst],
      children: [
        ContextClasses(
          classes: [
            ContextClass(
              name: 'domain_docs',
              band: 22,
              share: BudgetShare(minFraction: 0.1),
              cacheStable: true,
            ),
          ],
          child: Knowledge(
            label: 'API reference',
            text: Template.text('The Things API exposes GET /v1/things.'),
            className: 'domain_docs',
            child: Task(prompt: Template.text('What endpoints exist?'), agent: analyst),
          ),
        ),
      ],
    );

    final result = const BasicWorkflowCompiler().compileWithDiagnostics(pipeline);
    expect(result.diagnostics.where((d) => d.severity == CompileSeverity.error), isEmpty);

    // Audit shows the segment map statically.
    final audit = CapabilityAudit.of(result.program);
    expect(audit.toPrettyString(), contains('domain_docs'));
    expect(audit.toPrettyString(), contains('Context segments'));

    final fake = FakeVasterModel();
    final vm = await VasterVMEngine.bootstrap(config: VMConfig(defaultModel: fake));
    final runtime = VasterRuntime(
      vm: vm,
      policy: ExecutionPolicy.unlimited,
      budget: ExecutionBudget.unlimited(),
      scheduler: BasicVasterScheduler(taskQueue: PriorityTaskQueue()),
    );

    final state = await runtime.executeProgram(result.program);
    expect(state.status, equals(RuntimeStatus.halted));

    // Header table installed at load.
    expect(vm.contextManager.classTable.contains('domain_docs'), isTrue);

    // The agent's request: system segment populated from the role
    // instruction, knowledge band before the conversational tail.
    final request = fake.recordedRequests.last;
    expect(request.systemInstruction?.text, contains('analyze APIs carefully'));

    final texts = request.messages.map((m) => m.text).toList();
    final docIndex = texts.indexWhere((t) => t.contains('GET /v1/things'));
    final taskIndex = texts.indexWhere((t) => t.contains('What endpoints exist?'));
    expect(docIndex, isNot(-1), reason: 'knowledge region reaches the prompt');
    expect(taskIndex, isNot(-1));
    expect(docIndex, lessThan(taskIndex), reason: 'stable knowledge band renders before the volatile tail');
  });
}
