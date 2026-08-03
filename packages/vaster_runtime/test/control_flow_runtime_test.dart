import 'package:test/test.dart';
import 'package:vaster_ast/vaster_ast.dart';
import 'package:vaster_compiler/vaster_compiler.dart';
import 'package:vaster_domain/vaster_domain.dart';
import 'package:vaster_model_fake/vaster_model_fake.dart';
import 'package:vaster_vm/vaster_vm.dart';

void main() {
  group('Control flow — runtime execution', () {
    late FakeVasterModel fakeModel;
    late VasterVirtualMachine vm;
    late VasterRuntime runtime;

    Future<void> boot({ExecutionPolicy? policy}) async {
      fakeModel = FakeVasterModel();
      vm = await VasterVMEngine.bootstrap(
          config: VMConfig(defaultModel: fakeModel));
      runtime = VasterRuntime(
        vm: vm,
        policy: policy ?? ExecutionPolicy.unlimited,
        budget: ExecutionBudget.unlimited(),
        scheduler: BasicVasterScheduler(taskQueue: PriorityTaskQueue()),
      );
    }

    setUp(() => boot());

    tearDown(() async {
      await vm.shutdown();
    });

    Pipeline pipeline(List<VasterNode> children) => Pipeline(
          spec: const PipelineSpec(name: 'control_flow_runtime'),
          children: children,
        );

    const compiler = BasicWorkflowCompiler();

    test('hand-assembled counted loop: increments run exactly N times',
        () async {
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
          CompareRegisterOp(
              leftVar: 'i', operator: 'lt', rightValue: 3, targetVar: 'c'),
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

    test('compare uses loose equality across num/string register values',
        () async {
      const program = VasterProgram(
        programName: 'loose_eq',
        instructions: [
          SetRegisterOp(registerName: 'a', value: '5'),
          CompareRegisterOp(
              leftVar: 'a', operator: 'eq', rightValue: 5, targetVar: 'eq'),
          CompareRegisterOp(
              leftVar: 'a', operator: 'ge', rightValue: 4, targetVar: 'ge'),
          CompareRegisterOp(
              leftVar: 'a', operator: 'ne', rightValue: 6, targetVar: 'ne'),
          HaltOp(),
        ],
      );
      final state = await runtime.executeProgram(program);
      expect(state.registers['eq'], isTrue);
      expect(state.registers['ge'], isTrue);
      expect(state.registers['ne'], isTrue);
    });

    test('compiled Repeat runs its body exactly `times` times', () async {
      final program = compiler.compile(pipeline(const [
        Repeat(times: 4, children: [Prompt('loop body prompt')]),
      ]));

      final state = await runtime.executeProgram(program);
      expect(state.status, RuntimeStatus.halted);
      expect(fakeModel.recordedRequests, hasLength(4));
    });

    test('compiled While exits via maxIterations guard on an always-true '
        'condition', () async {
      final program = compiler.compile(pipeline(const [
        While(
          conditionVar: 'always',
          maxIterations: 3,
          children: [Prompt('while body')],
        ),
      ]));

      // Pre-set the condition register, then run without resetting state so
      // the loop sees a truthy condition forever — only the guard stops it.
      runtime.setRegister('always', true);
      final state = await runtime.executeProgram(program, resetState: false);

      expect(state.status, RuntimeStatus.halted);
      expect(fakeModel.recordedRequests, hasLength(3));
    });

    test('compiled While never runs the body on a falsy condition', () async {
      final program = compiler.compile(pipeline(const [
        While(conditionVar: 'unset', children: [Prompt('never')]),
      ]));
      final state = await runtime.executeProgram(program);
      expect(state.status, RuntimeStatus.halted);
      expect(fakeModel.recordedRequests, isEmpty);
    });

    test('TryCatch catches a VFS error, lands in catch with errorVar set',
        () async {
      final program = compiler.compile(pipeline(const [
        TryCatch(
          tryChildren: [ReadFile(path: '/not_mounted/missing.txt')],
          catchChildren: [Prompt('recovering from failure')],
          errorVar: 'err',
        ),
        Output(),
      ]));

      final state = await runtime.executeProgram(program);
      expect(state.status, RuntimeStatus.halted);
      expect(state.registers['err'], isNotNull);
      expect('${state.registers['err']}', isNotEmpty);
      // The catch block executed: its prompt reached the model and Output
      // captured the catch prompt's result.
      expect(fakeModel.recordedRequests, hasLength(1));
      expect('${state.registers['__output__']}', contains('recovering'));
    });

    test('the same error without TryCatch traps the VM', () async {
      final program = compiler.compile(pipeline(const [
        ReadFile(path: '/not_mounted/missing.txt'),
      ]));
      final state = await runtime.executeProgram(program);
      expect(state.status, RuntimeStatus.error);
      expect(state.errorDetails, contains('VASTER VM TRAP'));
    });

    test('a popped handler no longer catches later errors', () async {
      final program = compiler.compile(pipeline(const [
        TryCatch(
          tryChildren: [Prompt('fine')],
          catchChildren: [Prompt('should not run')],
        ),
        ReadFile(path: '/not_mounted/after_try.txt'),
      ]));
      final state = await runtime.executeProgram(program);
      expect(state.status, RuntimeStatus.error,
          reason: 'the handler was popped when the try block completed');
    });

    test('policy violations are NOT catchable by TryCatch', () async {
      await vm.shutdown();
      await boot(policy: ExecutionPolicy.readOnly);

      final program = compiler.compile(pipeline(const [
        TryCatch(
          tryChildren: [WriteFile(path: '/mnt/x.txt', content: 'data')],
          catchChildren: [Prompt('must never run')],
        ),
      ]));

      final state = await runtime.executeProgram(program);
      expect(state.status, RuntimeStatus.error);
      expect(state.errorDetails, contains('Policy violation'));
      expect(fakeModel.recordedRequests, isEmpty,
          reason: 'the catch block must not execute for policy traps');
    });

    test('subroutine call/return: body runs, result returns to caller',
        () async {
      fakeModel = FakeVasterModel(responseMap: {'hello sub': 'SUB_RESULT'});
      await vm.shutdown();
      vm = await VasterVMEngine.bootstrap(
          config: VMConfig(defaultModel: fakeModel));
      runtime = VasterRuntime(
        vm: vm,
        policy: ExecutionPolicy.unlimited,
        budget: ExecutionBudget.unlimited(),
        scheduler: BasicVasterScheduler(taskQueue: PriorityTaskQueue()),
      );

      final program = compiler.compile(pipeline(const [
        DefineSubroutine(name: 'greet', children: [Prompt('hello sub')]),
        CallSubroutine(name: 'greet'),
        Output(),
      ]));

      final state = await runtime.executeProgram(program);
      expect(state.status, RuntimeStatus.halted);
      expect(state.registers['__output__'], 'SUB_RESULT');
      expect(fakeModel.recordedRequests, hasLength(1));
    });

    test('execution continues after a subroutine returns', () async {
      final program = compiler.compile(pipeline(const [
        DefineSubroutine(name: 'noop', children: [Prompt('inside sub')]),
        CallSubroutine(name: 'noop'),
        Prompt('back in main'),
      ]));

      final state = await runtime.executeProgram(program);
      expect(state.status, RuntimeStatus.halted);
      expect(fakeModel.recordedRequests, hasLength(2));
      expect(fakeModel.recordedRequests.last.messages.last.text,
          contains('back in main'));
    });
  });
}
