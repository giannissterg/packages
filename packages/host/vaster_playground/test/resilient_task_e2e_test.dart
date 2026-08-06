import 'package:test/test.dart';
import 'package:vaster_ast/vaster_ast.dart';
import 'package:vaster_check/vaster_check.dart';
import 'package:vaster_compiler/vaster_compiler.dart';
import 'package:vaster_domain/vaster_domain.dart';
import 'package:vaster_model_fake/vaster_model_fake.dart';
import 'package:vaster_vm/vaster_vm.dart';

/// REL-P1's payoff, end to end through the compiler: `Resilient` around
/// a `Task` RETRIES now. Before the sealed-outcome work, a failed agent
/// dispatch wrote '' into its register and continued — TryCatch (and
/// therefore Resilient, which desugars to nested TryCatch) could never
/// observe the failure, so "retry" silently retried nothing.
void main() {
  const workerRole = AgentRole(
    roleId: 'worker',
    name: 'Worker',
    title: 'Worker',
    instruction: 'Do the work.',
  );

  Pipeline pipeline({required int attempts}) => Pipeline(
        name: 'resilient_task',
        result: const Binding('answer'),
        roles: const [workerRole],
        children: [
          Resilient(
            attempts: attempts,
            onExhausted: const [
              Inputs({Binding('answer'): 'gave-up'}),
            ],
            child: const Agent(
              role: workerRole,
              child: Task(
                prompt: Template.text('produce the answer'),
                output: Binding('answer'),
              ),
            ),
          ),
        ],
      );

  Future<RuntimeState> run(VasterProgram program, FakeVasterModel model) async {
    final vm = await VasterVMEngine.bootstrap(
        config: VMConfig(defaultModel: model));
    addTearDown(vm.shutdown);
    final runtime = VasterRuntime(
      vm: vm,
      policy: ExecutionPolicy.unlimited,
      budget: ExecutionBudget.unlimited(),
      scheduler: BasicVasterScheduler(taskQueue: PriorityTaskQueue()),
    );
    return runtime.executeProgram(program);
  }

  test('a transient failure heals: fail once, succeed on retry', () async {
    var calls = 0;
    final model = FakeVasterModel(handler: (request) {
      calls++;
      if (calls == 1) throw StateError('HTTP 503 transient blip');
      return ModelResponse(message: ChatMessage.model('42'));
    });

    final program =
        const BasicWorkflowCompiler().compile(pipeline(attempts: 3));
    final state = await run(program, model);

    expect(state.status, RuntimeStatus.halted);
    expect(calls, 2, reason: 'first attempt failed, second succeeded');
    expect(state.registers['answer'], '42',
        reason: 'the RETRY produced the answer — Resilient finally works '
            'for agent tasks');
  });

  test('exhaustion runs onExhausted instead of trapping', () async {
    var calls = 0;
    final model = FakeVasterModel(handler: (request) {
      calls++;
      throw StateError('permanently broken backend');
    });

    final program =
        const BasicWorkflowCompiler().compile(pipeline(attempts: 2));
    final state = await run(program, model);

    expect(state.status, RuntimeStatus.halted);
    expect(calls, 2, reason: 'exactly the declared attempts, then stop');
    expect(state.registers['answer'], 'gave-up',
        reason: 'the exhaustion branch owned the ending');
  });

  test('constant code size: attempts do not multiply instructions', () {
    const compiler = BasicWorkflowCompiler();
    final small = compiler.compile(pipeline(attempts: 2));
    final large = compiler.compile(pipeline(attempts: 50));
    expect(large.instructions.length, small.instructions.length,
        reason: 'Resilient lowers to a loop — the old desugar was '
            'O(attempts x child)');
  });

  test('the cost bound PRICES the declared retries', () {
    const compiler = BasicWorkflowCompiler();
    final once = ProgramChecker(pricingCatalog: PricingCatalog.builtin)
        .check(compiler.compile(pipeline(attempts: 1)))
        .costBound;
    final thrice = ProgramChecker(pricingCatalog: PricingCatalog.builtin)
        .check(compiler.compile(pipeline(attempts: 3)))
        .costBound;
    expect(once.unbounded, isFalse,
        reason: 'the retry loop guard is the canonical bounded shape');
    expect(thrice.maxModelCalls, 3 * once.maxModelCalls,
        reason: 'declared resilience is not free — the worst case '
            'multiplies by the attempt ceiling, and check says so before '
            'a token is spent');
  });
}
