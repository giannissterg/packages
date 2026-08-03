import 'package:test/test.dart';
import 'package:vaster_ast/vaster_ast.dart';
import 'package:vaster_compiler/vaster_compiler.dart';
import 'package:vaster_domain/vaster_domain.dart';
import 'package:vaster_instruction/vaster_instruction.dart';

void main() {
  const compiler = BasicWorkflowCompiler();

  Pipeline pipeline(List<VasterNode> children) => Pipeline(
        spec: const PipelineSpec(name: 'control_flow_test'),
        children: children,
      );

  group('Repeat lowering', () {
    test('emits counter init, compare, body, increment, and back-jump', () {
      final program = compiler.compile(pipeline(const [
        Repeat(times: 3, counterVar: 'i', children: [Prompt('body')]),
      ]));
      final instructions = program.instructions;

      final init = instructions.whereType<SetRegisterOp>().firstWhere(
            (op) => op.registerName == 'i',
          );
      expect(init.value, 0);

      final compare = instructions.whereType<CompareRegisterOp>().single;
      expect(compare.leftVar, 'i');
      expect(compare.operator, 'lt');
      expect(compare.rightValue, 3);

      final increment = instructions.whereType<IncrementRegisterOp>().single;
      expect(increment.registerName, 'i');
      expect(increment.delta, 1);

      // The loop must contain a backward jump (to re-evaluate the compare).
      final hasBackJump = instructions.indexed.any(
        (e) => e.$2 is JumpOp && (e.$2 as JumpOp).targetPc < e.$1,
      );
      expect(hasBackJump, isTrue);
    });
  });

  group('While lowering', () {
    test('emits maxIterations guard compare and user-condition jumpIf', () {
      final program = compiler.compile(pipeline(const [
        While(conditionVar: 'go', maxIterations: 7, children: [Prompt('body')]),
      ]));
      final instructions = program.instructions;

      final guard = instructions.whereType<CompareRegisterOp>().single;
      expect(guard.operator, 'lt');
      expect(guard.rightValue, 7);

      // One jumpIf tests the guard result, one tests the user condition.
      final conditionJump = instructions
          .whereType<JumpIfOp>()
          .where((op) => op.conditionVar == 'go');
      expect(conditionJump, hasLength(1));

      expect(instructions.whereType<IncrementRegisterOp>(), hasLength(1));
    });
  });

  group('TryCatch lowering', () {
    test('push/pop handler bracket the try block; target lands on catch', () {
      final program = compiler.compile(pipeline(const [
        TryCatch(
          tryChildren: [Prompt('try body')],
          catchChildren: [Prompt('catch body')],
          errorVar: 'err',
        ),
      ]));
      final instructions = program.instructions;

      final push = instructions.whereType<PushErrorHandlerOp>().single;
      expect(push.errorVar, 'err');
      expect(instructions.whereType<PopErrorHandlerOp>(), hasLength(1));

      // The handler target is the first catch-block instruction.
      final target = instructions[push.targetPc];
      expect(target, isA<PromptOp>());
      expect((target as PromptOp).promptText, 'catch body');

      // The pop must sit between push and the catch target (inside try).
      final popPc = instructions.indexWhere((op) => op is PopErrorHandlerOp);
      final pushPc = instructions.indexWhere((op) => op is PushErrorHandlerOp);
      expect(popPc, greaterThan(pushPc));
      expect(popPc, lessThan(push.targetPc));
    });
  });

  group('Subroutine lowering', () {
    test('body is emitted after halt; call targets it; return closes it', () {
      final program = compiler.compile(pipeline(const [
        DefineSubroutine(name: 'greet', children: [Prompt('hello sub')]),
        CallSubroutine(name: 'greet'),
        Output(),
      ]));
      final instructions = program.instructions;

      final call = instructions.whereType<CallOp>().single;
      expect(call.functionName, 'greet');

      final haltPc = instructions.indexWhere((op) => op is HaltOp);
      expect(call.targetPc, greaterThan(haltPc),
          reason: 'subroutine bodies live after the main halt');

      final entry = instructions[call.targetPc];
      expect(entry, isA<PromptOp>());
      expect((entry as PromptOp).promptText, 'hello sub');

      final ret = instructions.whereType<ReturnSubroutineOp>().single;
      expect(ret.returnRegister, entry.outputVar,
          reason: 'the body\'s last output register is the return value');
    });

    test('forward call (call before definition) resolves', () {
      final program = compiler.compile(pipeline(const [
        CallSubroutine(name: 'later'),
        DefineSubroutine(name: 'later', children: [Prompt('defined later')]),
      ]));
      expect(program.instructions.whereType<CallOp>().single.functionName, 'later');
    });

    test('call to an undefined subroutine is a compile error', () {
      final result = compiler.compileWithDiagnostics(pipeline(const [
        CallSubroutine(name: 'ghost'),
      ]));
      expect(result.hasErrors, isTrue);
      expect(result.errors.single.code, 'undefined_subroutine');
      expect(result.errors.single.message, contains('ghost'));

      expect(
        () => compiler.compile(pipeline(const [CallSubroutine(name: 'ghost')])),
        throwsStateError,
      );
    });
  });

  group('Analyzer integration', () {
    test('control-flow programs produce no error diagnostics', () {
      final result = compiler.compileWithDiagnostics(pipeline(const [
        Repeat(times: 2, children: [Prompt('a')]),
        TryCatch(tryChildren: [Prompt('b')], catchChildren: [Prompt('c')]),
        DefineSubroutine(name: 's', children: [Prompt('d')]),
        CallSubroutine(name: 's'),
      ]));
      expect(result.hasErrors, isFalse,
          reason: result.errors.map((e) => '$e').join('\n'));
    });

    test('optimizer keeps subroutine bodies alive (call-referenced labels)',
        () {
      const optimizing = BasicWorkflowCompiler(
        options: CompilerOptions(optimize: true),
      );
      final program = optimizing.compile(pipeline(const [
        DefineSubroutine(name: 'kept', children: [Prompt('kept body')]),
        CallSubroutine(name: 'kept'),
      ]));
      final call = program.instructions.whereType<CallOp>().single;
      final entry = program.instructions[call.targetPc];
      expect(entry, isA<PromptOp>());
      expect((entry as PromptOp).promptText, 'kept body');
      expect(
        program.instructions.whereType<ReturnSubroutineOp>(),
        hasLength(1),
      );
    });
  });
}
