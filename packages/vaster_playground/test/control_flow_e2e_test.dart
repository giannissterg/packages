import 'package:test/test.dart';
import 'package:vaster_ast/vaster_ast.dart';
import 'package:vaster_ast/primitives.dart';
import 'package:vaster_compiler/vaster_compiler.dart';
import 'package:vaster_domain/vaster_domain.dart';
import 'package:vaster_model_fake/vaster_model_fake.dart';
import 'package:vaster_vm/vaster_vm.dart';

/// Compiler → ISA → runtime E2E coverage for control-flow AST nodes.
///
/// Lives in the playground because runtime packages must not depend on the
/// compiler frontend; ISA-level control-flow behavior is tested in
/// `vaster_runtime/test/control_flow_runtime_test.dart` with hand-assembled
/// programs.
void main() {
  group('Control flow — compiled pipeline execution', () {
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

    Pipeline pipeline(List<VasterNode> children, {Binding? result}) =>
      Pipeline(
        result: result,
          spec: const PipelineSpec(name: 'control_flow_e2e'),
          children: children,
        );

    const compiler = BasicWorkflowCompiler();

    test('compiled Repeat runs its body exactly `times` times', () async {
      final program = compiler.compile(pipeline(const [
        Repeat(times: 4, children: [Prompt(Template.text('loop body prompt'))]),
      ]));

      final state = await runtime.executeProgram(program);
      expect(state.status, RuntimeStatus.halted);
      expect(fakeModel.recordedRequests, hasLength(4));
    });

    test('compiled While exits via maxIterations guard on an always-true '
        'condition', () async {
      final program = compiler.compile(pipeline(const [
        While(
          condition: 'always',
          maxIterations: 3,
          children: [Prompt(Template.text('while body'))],
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
        While(condition: 'unset', children: [Prompt(Template.text('never'))]),
      ]));
      final state = await runtime.executeProgram(program);
      expect(state.status, RuntimeStatus.halted);
      expect(fakeModel.recordedRequests, isEmpty);
    });

    test('TryCatch catches a VFS error, lands in catch with errorVar set',
        () async {
      final program = compiler.compile(pipeline(const [
        TryCatch(
          tryChildren: [ReadFile(path: Template.text('/not_mounted/missing.txt'))],
          catchChildren: [
            Prompt(Template.text('recovering from failure'),
                output: Binding('recovery'))
          ],
          error: 'err',
        ),
      ], result: const Binding('recovery')));

      final state = await runtime.executeProgram(program);
      expect(state.status, RuntimeStatus.halted);
      expect(state.registers['err'], isNotNull);
      expect('${state.registers['err']}', isNotEmpty);
      // The catch block executed: its prompt reached the model and its
      // result landed in the declared result binding.
      expect(fakeModel.recordedRequests, hasLength(1));
      expect('${state.registers['recovery']}', contains('recovering'));
    });

    test('the same error without TryCatch traps the VM', () async {
      final program = compiler.compile(pipeline(const [
        ReadFile(path: Template.text('/not_mounted/missing.txt')),
      ]));
      final state = await runtime.executeProgram(program);
      expect(state.status, RuntimeStatus.error);
      expect(state.errorDetails, contains('VASTER VM TRAP'));
    });

    test('a popped handler no longer catches later errors', () async {
      final program = compiler.compile(pipeline(const [
        TryCatch(
          tryChildren: [Prompt(Template.text('fine'))],
          catchChildren: [Prompt(Template.text('should not run'))],
        ),
        ReadFile(path: Template.text('/not_mounted/after_try.txt')),
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
          tryChildren: [WriteFile(path: Template.text('/mnt/x.txt'), content: Template.text('data'))],
          catchChildren: [Prompt(Template.text('must never run'))],
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
        DefineSubroutine(name: 'greet', children: [Prompt(Template.text('hello sub'))]),
        CallSubroutine(name: 'greet', output: 'sub_result'),
      ], result: const Binding('sub_result')));

      final state = await runtime.executeProgram(program);
      expect(state.status, RuntimeStatus.halted);
      expect(state.registers['sub_result'], 'SUB_RESULT');
      expect(fakeModel.recordedRequests, hasLength(1));
    });

    test('execution continues after a subroutine returns', () async {
      final program = compiler.compile(pipeline(const [
        DefineSubroutine(name: 'noop', children: [Prompt(Template.text('inside sub'))]),
        CallSubroutine(name: 'noop'),
        Prompt(Template.text('back in main')),
      ]));

      final state = await runtime.executeProgram(program);
      expect(state.status, RuntimeStatus.halted);
      expect(fakeModel.recordedRequests, hasLength(2));
      expect(fakeModel.recordedRequests.last.messages.last.text,
          contains('back in main'));
    });
  });
}
