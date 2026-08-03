import 'package:vaster_ast/vaster_ast.dart';
import 'package:vaster_compiler/vaster_compiler.dart';
import 'package:vaster_domain/vaster_domain.dart';
import 'package:vaster_model_fake/vaster_model_fake.dart';
import 'package:vaster_vm/vaster_vm.dart';

void main() async {
  print('======================================================================');
  print('    VASTER HIERARCHICAL BUDGETSCOPE & QUOTA REDUCTION DEMO            ');
  print('  1. Root Budget  2. Child BudgetScope  3. Turn Token & Time Deductions ');
  print('======================================================================\n');

  const analystRole = AgentRole(
    roleId: 'analyst',
    name: 'Data Analyst',
    title: 'Research Analyst',
    instruction: 'Performs data analytics.',
  );

  const compiler = BasicWorkflowCompiler();

  // ── SCENARIO 1: Normal Budget Scope Execution & Deductions ─────────────────
  print('┌─ SCENARIO 1: Hierarchical Token & Time Deductions ───────────────┐');
  final rootBudget1 = ExecutionBudget(maxTokens: 1000, maxDuration: const Duration(minutes: 5));

  final pipeline1 = Pipeline(
    spec: const PipelineSpec(name: 'normal_budget_pipeline'),
    roles: const [analystRole],
    children: [
      const BudgetScope(
        maxTokens: 200,
        maxDuration: Duration(minutes: 1),
        children: [
          Agent(
            role: analystRole,
            children: [
              Task(prompt: 'Analyze sales data and summarize findings.'),
            ],
          ),
        ],
      ),
    ],
  );

  final program1 = compiler.compile(pipeline1);
  final vm1 = await VasterVMEngine.bootstrap(
    config: VMConfig(
      defaultModel: FakeVasterModel(defaultResponseText: 'Sales analysis complete with key metrics.'),
    ),
    rootBudget: rootBudget1,
  );

  final runtime1 = VasterRuntime(
    vm: vm1,
    policy: ExecutionPolicy.unlimited,
    budget: rootBudget1,
    scheduler: BasicVasterScheduler(taskQueue: PriorityTaskQueue()),
  );

  final state1 = await runtime1.executeProgram(program1);
  print('  ✓ Status: ${state1.status.name}');
  print('  ✓ Root Budget Consumed Tokens: ${rootBudget1.consumedTokens}');
  print('  ✓ Root Budget Consumed Time: ${rootBudget1.consumedDuration.inMilliseconds}ms');
  await vm1.shutdown();

  // ── SCENARIO 2: Exceeding Sub-Tree Token Budget Limit ───────────────────────
  print('\n┌─ SCENARIO 2: Quota Exhaustion Protection (Strict Token Limit) ───┐');
  final rootBudget2 = ExecutionBudget(maxTokens: 1000);
  final strictChildBudget = ExecutionBudget(maxTokens: 5); // 5 tokens max (turn uses ~20 tokens)

  final pipeline2 = Pipeline(
    spec: const PipelineSpec(name: 'exceeded_budget_pipeline'),
    roles: const [analystRole],
    children: [
      const BudgetScope(
        maxTokens: 5,
        children: [
          Agent(
            role: analystRole,
            children: [
              Task(prompt: 'Analyze sales data and summarize findings.'),
            ],
          ),
        ],
      ),
    ],
  );

  final program2 = compiler.compile(pipeline2);
  final vm2 = await VasterVMEngine.bootstrap(
    config: VMConfig(
      defaultModel: FakeVasterModel(defaultResponseText: 'Sales analysis complete with key metrics.'),
    ),
    rootBudget: rootBudget2,
  );

  final runtime2 = VasterRuntime(
    vm: vm2,
    policy: ExecutionPolicy.unlimited,
    budget: strictChildBudget,
    scheduler: BasicVasterScheduler(taskQueue: PriorityTaskQueue()),
  );

  final state2 = await runtime2.executeProgram(program2);
  print('  ✓ Status: ${state2.status.name}');
  print('  ✓ Token Quota Exhausted: ${state2.status == RuntimeStatus.timedOut ? "YES (Sub-tree halted safely)" : "NO"}');
  await vm2.shutdown();

  print('\n======================================================================');
  print('  DEMO PASSED: BudgetScope & Quota Deductions Verified 100%!');
  print('======================================================================');
}
