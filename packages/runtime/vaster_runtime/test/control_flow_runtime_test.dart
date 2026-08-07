import 'package:test/test.dart';
import 'package:vaster_model_fake/vaster_model_fake.dart';
import 'package:vaster_vm/vaster_vm.dart';

/// ISA-level control-flow coverage with hand-assembled programs.
///
/// Compiler → ISA → runtime E2E coverage for the corresponding AST nodes lives
/// in `vaster_playground/test/control_flow_e2e_test.dart` — runtime packages
/// must not depend on the compiler frontend.
void main() {
  group('Control flow — runtime execution', () {
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

    tearDown(() async {
      await vm.shutdown();
    });

    test('hand-assembled counted loop: increments run exactly N times', () async {
      // 0: i = 0
      // 1: total = 0
      // 2: c = (i < 3)
      // 3: jumpIf c -> 5
      // 4: jump -> 8
      // 5: total += 2      (body)
      // 6: i += 1
      // 7: jump -> 2
      // 8: halt
      const program = VasterProgram(
        programName: 'counted_loop',
        instructions: [
          SetRegisterOp(registerName: 'i', value: 0),
          SetRegisterOp(registerName: 'total', value: 0),
          CompareRegisterOp(leftVar: 'i', operator: 'lt', rightValue: 3, targetVar: 'c'),
          JumpIfOp(conditionVar: 'c', targetPc: 5),
          JumpOp(targetPc: 8),
          IncrementRegisterOp(registerName: 'total', delta: 2),
          IncrementRegisterOp(registerName: 'i'),
          JumpOp(targetPc: 2),
          HaltOp(),
        ],
      );

      final state = await runtime.executeProgram(program);
      expect(state.status, RuntimeStatus.halted);
      expect(state.registers['i'], 3);
      expect(state.registers['total'], 6);
    });

    test('compare uses loose equality across num/string register values', () async {
      const program = VasterProgram(
        programName: 'loose_eq',
        instructions: [
          SetRegisterOp(registerName: 'a', value: '5'),
          CompareRegisterOp(leftVar: 'a', operator: 'eq', rightValue: 5, targetVar: 'eq'),
          CompareRegisterOp(leftVar: 'a', operator: 'ge', rightValue: 4, targetVar: 'ge'),
          CompareRegisterOp(leftVar: 'a', operator: 'ne', rightValue: 6, targetVar: 'ne'),
          HaltOp(),
        ],
      );
      final state = await runtime.executeProgram(program);
      expect(state.registers['eq'], isTrue);
      expect(state.registers['ge'], isTrue);
      expect(state.registers['ne'], isTrue);
    });
  });
}
