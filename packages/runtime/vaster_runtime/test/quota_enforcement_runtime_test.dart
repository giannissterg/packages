import 'package:test/test.dart';
import 'package:vaster_model_fake/vaster_model_fake.dart';
import 'package:vaster_vm/vaster_vm.dart';

/// SetQuotaOp is real runtime semantics: the quota a program declares
/// (compiled from `BudgetScope`) binds from the instruction it executes at.
void main() {
  group('SetQuotaOp enforcement', () {
    late VasterVirtualMachine vm;
    late VasterRuntime runtime;

    setUp(() async {
      vm = await VasterVMEngine.bootstrap(config: VMConfig(defaultModel: FakeVasterModel()));
      runtime = VasterRuntime(
        vm: vm,
        policy: ExecutionPolicy.unlimited,
        budget: ExecutionBudget.unlimited(),
        scheduler: BasicVasterScheduler(taskQueue: PriorityTaskQueue()),
      );
    });

    test('token quota breach traps the machine', () async {
      final program = const VasterProgram(
        programName: 'quota_tokens',
        instructions: [
          SetQuotaOp(quota: ResourceQuota(maxTokenBudget: 1)),
          PromptOp(promptText: 'Write a long essay about resource governance.', outputVar: 'essay'),
          HaltOp(),
        ],
      );

      final state = await runtime.executeProgram(program);

      expect(state.status, equals(RuntimeStatus.error));
      expect(state.errorDetails, contains('QuotaExceededException'));
      expect(state.errorDetails, contains('tokens'));
    });

    test('deadline quota breach traps at the next instruction boundary', () async {
      final program = const VasterProgram(
        programName: 'quota_deadline',
        instructions: [
          SetQuotaOp(quota: ResourceQuota(timeDeadline: Duration.zero)),
          SetRegisterOp(registerName: 'never', value: 'ran'),
          HaltOp(),
        ],
      );

      final state = await runtime.executeProgram(program);

      expect(state.status, equals(RuntimeStatus.error));
      expect(state.errorDetails, contains('deadline'));
      expect(state.registers.containsKey('never'), isFalse);
    });

    test('quota breach is recoverable by a program error handler', () async {
      final program = const VasterProgram(
        programName: 'quota_recovered',
        instructions: [
          PushErrorHandlerOp(targetPc: 4, errorVar: 'quota_error'),
          SetQuotaOp(quota: ResourceQuota(maxTokenBudget: 1)),
          PromptOp(promptText: 'Overflow the one-token budget.', outputVar: 'out'),
          HaltOp(),
          SetRegisterOp(registerName: 'recovered', value: 'yes'),
          HaltOp(),
        ],
      );

      final state = await runtime.executeProgram(program);

      expect(state.status, equals(RuntimeStatus.halted));
      expect(state.registers['recovered'], equals('yes'));
      expect('${state.registers['quota_error']}', contains('QuotaExceededException'));
    });

    test('a generous quota does not interfere with execution', () async {
      final program = const VasterProgram(
        programName: 'quota_generous',
        instructions: [
          SetQuotaOp(quota: ResourceQuota(maxTokenBudget: 1000000, timeDeadline: Duration(minutes: 5))),
          PromptOp(promptText: 'Say hello.', outputVar: 'greeting'),
          HaltOp(),
        ],
      );

      final state = await runtime.executeProgram(program);

      expect(state.status, equals(RuntimeStatus.halted));
      expect(state.registers['greeting'], isNotNull);
    });

    test('a later SetQuotaOp replaces the earlier quota and its counters', () async {
      // Each fake prompt+echo costs ~19 tokens: one fits in a 30-token scope,
      // two do not — so this halts only if the second SetQuotaOp resets the
      // counters.
      final program = const VasterProgram(
        programName: 'quota_replaced',
        instructions: [
          SetQuotaOp(quota: ResourceQuota(maxTokenBudget: 30)),
          PromptOp(promptText: 'First scope prompt.', outputVar: 'a'),
          SetQuotaOp(quota: ResourceQuota(maxTokenBudget: 30)),
          PromptOp(promptText: 'Second scope prompt.', outputVar: 'b'),
          HaltOp(),
        ],
      );

      final state = await runtime.executeProgram(program);

      expect(state.status, equals(RuntimeStatus.halted));
      expect(state.registers['b'], isNotNull);
    });

    test('a cost ceiling on an unpriced backend publishes an unenforced-cost '
        'warning', () async {
      // A model the pricing catalog cannot rate and that reports no cost.
      final unpricedVm = await VasterVMEngine.bootstrap(
        config: VMConfig(defaultModel: FakeVasterModel(modelName: 'mystery-backend')),
      );
      final unpricedRuntime = VasterRuntime(
        vm: unpricedVm,
        policy: ExecutionPolicy.unlimited,
        budget: ExecutionBudget.unlimited(),
        scheduler: BasicVasterScheduler(taskQueue: PriorityTaskQueue()),
      );
      final warnings = <RuntimeWarningEvent>[];
      unpricedVm.eventBus.on<RuntimeWarningEvent>().listen(warnings.add);

      final program = const VasterProgram(
        programName: 'quota_cost',
        instructions: [
          SetQuotaOp(quota: ResourceQuota(maxCostBudget: 5.0)),
          HaltOp(),
        ],
      );

      final state = await unpricedRuntime.executeProgram(program);
      await Future<void>.delayed(Duration.zero); // let the event deliver

      expect(state.status, equals(RuntimeStatus.halted));
      expect(warnings.map((w) => w.code), contains('cost_quota_unenforced'));
    });

    test('no cost warning when the backend is priced by the catalog', () async {
      // The default fake's modelName is priced (free) in the builtin catalog.
      final warnings = <RuntimeWarningEvent>[];
      vm.eventBus.on<RuntimeWarningEvent>().listen(warnings.add);

      final program = const VasterProgram(
        programName: 'quota_cost_priced',
        instructions: [
          SetQuotaOp(quota: ResourceQuota(maxCostBudget: 5.0)),
          HaltOp(),
        ],
      );

      final state = await runtime.executeProgram(program);
      await Future<void>.delayed(Duration.zero);

      expect(state.status, equals(RuntimeStatus.halted));
      expect(warnings, isEmpty);
    });

    test('cost quota trips on wire-reported cost', () async {
      final costVm = await VasterVMEngine.bootstrap(
        config: VMConfig(
          defaultModel: FakeVasterModel(
            usageBuilder: (request, responseText) => const UsageMetadata(
              promptTokenCount: 10,
              candidatesTokenCount: 5,
              costUsd: 3.0,
              source: UsageSource.measured,
            ),
          ),
        ),
      );
      final costRuntime = VasterRuntime(
        vm: costVm,
        policy: ExecutionPolicy.unlimited,
        budget: ExecutionBudget.unlimited(),
        scheduler: BasicVasterScheduler(taskQueue: PriorityTaskQueue()),
      );

      // Two prompts at $3 each against a $5 ceiling: the second breaches.
      final program = const VasterProgram(
        programName: 'quota_cost_trip',
        instructions: [
          SetQuotaOp(quota: ResourceQuota(maxCostBudget: 5.0)),
          PromptOp(promptText: 'First expensive call.', outputVar: 'a'),
          PromptOp(promptText: 'Second expensive call.', outputVar: 'b'),
          HaltOp(),
        ],
      );

      final state = await costRuntime.executeProgram(program);

      expect(state.status, equals(RuntimeStatus.error));
      expect(state.errorDetails, contains('QuotaExceededException'));
      expect(state.errorDetails, contains('cost'));
      expect(state.registers['a'], isNotNull);
      expect(state.registers.containsKey('b'), isFalse);
    });
  });
}
