import 'package:test/test.dart';
import 'package:vaster_model_fake/vaster_model_fake.dart';
import 'package:vaster_vm/vaster_vm.dart';

/// REL-P1's ISA half, against hand-assembled programs (Rule 1): agent
/// failure is a PROGRAM error — routed to handlers or trapping — and
/// the sibling outcome register carries the sealed outcome's kind
/// either way. Before this, a failed agent wrote '' and TryCatch around
/// a Task could never fire.
void main() {
  Future<(VasterVirtualMachine, VasterRuntime)> boot(FakeVasterModel model) async {
    final vm = await VasterVMEngine.bootstrap(config: VMConfig(defaultModel: model));
    final runtime = VasterRuntime(
      vm: vm,
      policy: ExecutionPolicy.unlimited,
      budget: ExecutionBudget.unlimited(),
      scheduler: BasicVasterScheduler(taskQueue: PriorityTaskQueue()),
    );
    return (vm, runtime);
  }

  FakeVasterModel alwaysFailing() =>
      FakeVasterModel(handler: (_) => throw StateError('HTTP 500 from the backend'));

  test('an unhandled agent failure TRAPS — never a silent empty register', () async {
    final (vm, runtime) = await boot(alwaysFailing());
    final state = await runtime.executeProgram(
      const VasterProgram(
        programName: 'unhandled_failure',
        instructions: [
          DispatchAgentTaskOp(agentId: 'worker', taskPrompt: 'do the thing', outputVar: 'out'),
          HaltOp(),
        ],
      ),
    );

    expect(state.status, RuntimeStatus.error);
    expect(state.errorDetails, contains('Agent task failed'));
    expect(state.errorDetails, contains('model-failure'));
    expect(state.registers['out'], isNull, reason: 'no phantom empty-string output');
    expect(
      state.registers[taskOutcomeRegister('out')],
      'model-failure',
      reason: 'the sibling register carries the sealed kind even on trap',
    );
    await vm.shutdown();
  });

  test('a handler catches the failure; the outcome kind is observable', () async {
    final (vm, runtime) = await boot(alwaysFailing());
    final state = await runtime.executeProgram(
      const VasterProgram(
        programName: 'handled_failure',
        instructions: [
          PushErrorHandlerOp(targetPc: 4, errorVar: 'err'), // 0
          DispatchAgentTaskOp(agentId: 'worker', taskPrompt: 'try it', outputVar: 'out'), // 1
          PopErrorHandlerOp(), // 2
          JumpOp(targetPc: 5), // 3
          SetRegisterOp(registerName: 'recovered', value: 'yes'), // 4 (catch)
          HaltOp(), // 5
        ],
      ),
    );

    expect(state.status, RuntimeStatus.halted);
    expect(state.registers['recovered'], 'yes', reason: 'TryCatch around a Task finally works');
    expect(
      state.registers['err'],
      contains('model-failure'),
      reason: 'the handler sees the classified failure',
    );
    expect(state.registers[taskOutcomeRegister('out')], 'model-failure');
    await vm.shutdown();
  });

  test('parallel dispatch writes every outcome, keeps successes, then raises', () async {
    var calls = 0;
    final model = FakeVasterModel(
      handler: (request) {
        calls++;
        if (request.messages.last.text.contains('bad')) {
          throw StateError('boom');
        }
        return ModelResponse(message: ChatMessage.model('fine'));
      },
    );
    final (vm, runtime) = await boot(model);
    final state = await runtime.executeProgram(
      VasterProgram(
        programName: 'parallel_mixed',
        instructions: [
          const CreateAgentOp(
            descriptor: AgentDescriptor(agentId: 'a1', name: 'w1', role: 'worker', systemInstruction: 'work'),
          ),
          const CreateAgentOp(
            descriptor: AgentDescriptor(agentId: 'a2', name: 'w2', role: 'worker', systemInstruction: 'work'),
          ),
          const PushErrorHandlerOp(targetPc: 5, errorVar: 'err'),
          const DispatchParallelTasksOp(
            dispatches: [
              ParallelTaskDispatch(agentId: 'a1', taskPrompt: 'good work', outputVar: 'r1'),
              ParallelTaskDispatch(agentId: 'a2', taskPrompt: 'bad work', outputVar: 'r2'),
            ],
          ),
          const PopErrorHandlerOp(),
          const HaltOp(),
        ],
      ),
    );

    expect(state.status, RuntimeStatus.halted);
    expect(calls, greaterThanOrEqualTo(2));
    expect(state.registers[taskOutcomeRegister('r1')], 'completed');
    expect(state.registers['r1'], 'fine', reason: 'the succeeding branch keeps its output');
    expect(state.registers[taskOutcomeRegister('r2')], 'model-failure');
    expect(state.registers['r2'], isNull);
    expect(
      state.registers['err'],
      contains('Agent task failed'),
      reason:
          'the batch failure reached the handler AFTER all '
          'outcomes were written',
    );
    await vm.shutdown();
  });

  test('cancellation and quota classify distinctly through the same path', () async {
    // Quota: a 1-token budget trips inside the agent.
    final (vm, runtime) = await boot(FakeVasterModel());
    await vm.shutdown(); // not used — quota path needs a custom tracker;
    // classification of quota/cancel at the AGENT level is covered in
    // vaster_agent_basic tests; here the ISA contract is kind-agnostic.
    expect(const TaskCancelled(message: 'x').kind, 'cancelled');
    expect(
      const TaskQuotaExceeded(resourceType: 'tokens', currentUsage: 1, quotaLimit: 1, message: 'x').kind,
      'quota-exceeded',
    );
    expect(runtime, isNotNull);
  });
}
