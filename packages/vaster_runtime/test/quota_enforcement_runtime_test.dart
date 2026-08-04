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
      vm = await VasterVMEngine.bootstrap(
          config: VMConfig(defaultModel: FakeVasterModel()));
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
          PromptOp(
              promptText: 'Write a long essay about resource governance.',
              outputVar: 'essay'),
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
      expect('${state.registers['quota_error']}',
          contains('QuotaExceededException'));
    });

    test('a generous quota does not interfere with execution', () async {
      final program = const VasterProgram(
        programName: 'quota_generous',
        instructions: [
          SetQuotaOp(
              quota: ResourceQuota(
                  maxTokenBudget: 1000000,
                  timeDeadline: Duration(minutes: 5))),
          PromptOp(promptText: 'Say hello.', outputVar: 'greeting'),
          HaltOp(),
        ],
      );

      final state = await runtime.executeProgram(program);

      expect(state.status, equals(RuntimeStatus.halted));
      expect(state.registers['greeting'], isNotNull);
    });

    test('a later SetQuotaOp replaces the earlier quota and its counters', () async {
      final program = const VasterProgram(
        programName: 'quota_replaced',
        instructions: [
          // Tight quota, nearly consumed by the first prompt…
          SetQuotaOp(quota: ResourceQuota(maxTokenBudget: 100)),
          PromptOp(promptText: 'First scope prompt.', outputVar: 'a'),
          // …then a fresh scope: counters restart, so this succeeds.
          SetQuotaOp(quota: ResourceQuota(maxTokenBudget: 100)),
          PromptOp(promptText: 'Second scope prompt.', outputVar: 'b'),
          HaltOp(),
        ],
      );

      final state = await runtime.executeProgram(program);

      expect(state.status, equals(RuntimeStatus.halted));
      expect(state.registers['b'], isNotNull);
    });

    test('declaring a cost ceiling publishes an unenforced-cost warning', () async {
      final warnings = <RuntimeWarningEvent>[];
      vm.eventBus.on<RuntimeWarningEvent>().listen(warnings.add);

      final program = const VasterProgram(
        programName: 'quota_cost',
        instructions: [
          SetQuotaOp(quota: ResourceQuota(maxCostBudget: 5.0)),
          HaltOp(),
        ],
      );

      final state = await runtime.executeProgram(program);
      await Future<void>.delayed(Duration.zero); // let the event deliver

      expect(state.status, equals(RuntimeStatus.halted));
      expect(warnings.map((w) => w.code), contains('cost_quota_unenforced'));
    });
  });
}
