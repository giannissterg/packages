import 'package:test/test.dart';
import 'package:vaster_model_fake/vaster_model_fake.dart';
import 'package:vaster_vm/vaster_vm.dart';

/// Agent dispatch ops must charge the task tree's REAL accumulated usage —
/// `DispatchParallelTasksOp` previously charged nothing at all, and
/// `DispatchAgentTaskOp` previously charged a length heuristic even when the
/// backend reported exact numbers.
void main() {
  const descriptor = AgentDescriptor(
    agentId: 'worker',
    name: 'Worker',
    role: 'test worker',
    systemInstruction: 'You do the thing.',
  );

  VasterRuntime runtimeFor(VasterVirtualMachine vm) => VasterRuntime(
        vm: vm,
        policy: ExecutionPolicy.unlimited,
        budget: ExecutionBudget.unlimited(),
        scheduler: BasicVasterScheduler(taskQueue: PriorityTaskQueue()),
      );

  test('DispatchAgentTaskOp charges the model-reported usage', () async {
    // Pin exact usage so the assertion is about plumbing, not estimation.
    final vm = await VasterVMEngine.bootstrap(
      config: VMConfig(
        defaultModel: FakeVasterModel(
          usageBuilder: (request, responseText) => const UsageMetadata(
            promptTokenCount: 111,
            candidatesTokenCount: 22,
            source: UsageSource.measured,
          ),
        ),
      ),
    );
    final runtime = runtimeFor(vm);

    final program = VasterProgram(
      programName: 'single_dispatch_usage',
      instructions: [
        CreateAgentOp(descriptor: descriptor),
        const DispatchAgentTaskOp(
            agentId: 'worker', taskPrompt: 'Do the thing.', outputVar: 'out'),
        const HaltOp(),
      ],
    );

    final state = await runtime.executeProgram(program);

    expect(state.status, equals(RuntimeStatus.halted));
    expect(runtime.budget.consumedTokens, equals(133));
  });

  test('DispatchParallelTasksOp charges the summed usage of all task trees',
      () async {
    final vm = await VasterVMEngine.bootstrap(
      config: VMConfig(
        defaultModel: FakeVasterModel(
          usageBuilder: (request, responseText) => const UsageMetadata(
            promptTokenCount: 50,
            candidatesTokenCount: 10,
            source: UsageSource.measured,
          ),
        ),
      ),
    );
    final runtime = runtimeFor(vm);

    final program = VasterProgram(
      programName: 'parallel_dispatch_usage',
      instructions: [
        CreateAgentOp(descriptor: descriptor),
        const DispatchParallelTasksOp(dispatches: [
          ParallelTaskDispatch(
              agentId: 'worker', taskPrompt: 'Task A', outputVar: 'a'),
          ParallelTaskDispatch(
              agentId: 'worker', taskPrompt: 'Task B', outputVar: 'b'),
        ]),
        const HaltOp(),
      ],
    );

    final state = await runtime.executeProgram(program);

    expect(state.status, equals(RuntimeStatus.halted));
    expect(state.registers['a'], isNotNull);
    expect(state.registers['b'], isNotNull);
    // Two tasks × 60 tokens each — before the fix this path charged zero.
    expect(runtime.budget.consumedTokens, equals(120));
  });
}
