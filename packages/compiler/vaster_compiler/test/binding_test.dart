import 'package:test/test.dart';
import 'package:vaster_ast/vaster_ast.dart';
import 'package:vaster_compiler/vaster_compiler.dart';
import 'package:vaster_instruction/vaster_instruction.dart';

void main() {
  group('Binding', () {
    test('compiles away to its register name', () {
      const spec = Binding('spec');
      const pipeline = Pipeline(
        name: 'b',
        children: [Prompt(Template.text('Write the spec.'), output: spec)],
      );
      final program = const BasicWorkflowCompiler().compile(pipeline);
      final op = program.instructions.whereType<PromptOp>().first;
      expect(op.outputVar, equals('spec'));
    });

    test('reserved __ prefix is a compile error', () {
      const pipeline = Pipeline(
        name: 'r',
        children: [Prompt(Template.text('x'), output: Binding('__sneaky'))],
      );
      final result = const BasicWorkflowCompiler().compileWithDiagnostics(pipeline);
      expect(result.diagnostics.map((d) => d.code), contains('reserved_binding'));
    });

    test('the name is the wire: same-named bindings hit the same register', () {
      // Object identity is irrelevant — two distinct Binding('x') instances
      // compile to one register (identity equality keeps Binding legal as a
      // const map key in Inputs).
      final program = const BasicWorkflowCompiler().compile(
        const Pipeline(
          name: 'wire',
          children: [
            Prompt(Template.text('produce'), output: Binding('x')),
            Prompt(Template([r'consume ', Binding('x')]), output: Binding('y')),
          ],
        ),
      );
      final ops = program.instructions.whereType<PromptOp>().toList();
      expect(ops[0].outputVar, equals('x'));
      expect(ops[1].promptText, contains(r'${x}'));

      expect(const Binding('spec').inNamespace('checkout').name, equals('checkout_spec'));
      expect(const Binding('spec').inNamespace('').name, equals('spec'));
    });

    test('invalid template parts are compile errors', () {
      final result = const BasicWorkflowCompiler().compileWithDiagnostics(
        const Pipeline(
          name: 'bad',
          children: [
            Prompt(Template(['ok ', 42])),
          ],
        ),
      );
      expect(result.diagnostics.map((d) => d.code), contains('invalid_template_part'));
    });

    test('raw \${} inside template text draws a warning', () {
      final result = const BasicWorkflowCompiler().compileWithDiagnostics(
        const Pipeline(name: 'rawref', children: [Prompt(Template.text(r'sneaky ${direct_register}'))]),
      );
      expect(result.diagnostics.map((d) => d.code), contains('raw_interpolation_in_template'));
      // Warning, not error — the escape hatch still compiles.
      expect(result.hasErrors, isFalse);
    });

    test('Cond.equals lowers to CompareRegisterOp + JumpIf', () {
      const verdict = Binding('verdict');
      final program = const BasicWorkflowCompiler().compile(
        const Pipeline(
          name: 'cond',
          children: [
            Prompt(Template.text('judge'), output: verdict),
            When(
              condition: Cond.equals(verdict, 'approve'),
              then: [WriteFile(path: Template.text('/mem/ok.txt'), content: Template.text('shipped'))],
            ),
          ],
        ),
      );
      final cmp = program.instructions.whereType<CompareRegisterOp>().single;
      expect(cmp.leftVar, equals('verdict'));
      expect(cmp.operator, equals('eq'));
      expect(cmp.rightValue, equals('approve'));
      final jump = program.instructions.whereType<JumpIfOp>().single;
      expect(jump.conditionVar, equals(cmp.targetVar));
    });

    test('Cond.not swaps branches at compile time — no runtime negation', () {
      const flag = Binding('flag');
      final program = const BasicWorkflowCompiler().compile(
        const Pipeline(
          name: 'notcond',
          children: [
            When(
              condition: Cond.not(Cond.isTrue(flag)),
              then: [WriteFile(path: Template.text('/mem/no.txt'), content: Template.text('flag was falsy'))],
              otherwise: [
                WriteFile(path: Template.text('/mem/yes.txt'), content: Template.text('flag was truthy')),
              ],
            ),
          ],
        ),
      );
      // No compare op emitted; the jumpIf targets the register directly and
      // the THEN branch (jump target) holds the *otherwise* body.
      expect(program.instructions.whereType<CompareRegisterOp>(), isEmpty);
      final jump = program.instructions.whereType<JumpIfOp>().single;
      expect(jump.conditionVar, equals('flag'));
      final jumpTargetWrites = program.instructions.skip(jump.targetPc).whereType<WriteFileOp>().first;
      expect(
        jumpTargetWrites.vfsPath,
        equals('/mem/yes.txt'),
        reason: 'truthy flag lands in the otherwise body under not()',
      );
    });

    test('Pipeline(result:) lands in the program header and survives VBC', () {
      const pipeline = Pipeline(
        name: 'result_header',
        result: Binding('answer'),
        children: [Prompt(Template.text('answer me'), output: Binding('answer'))],
      );
      final program = const BasicWorkflowCompiler().compile(pipeline);
      expect(program.resultBinding, equals('answer'));
      // No ConcatRegisterOp/__output__ machinery anymore.
      expect(program.instructions.whereType<ConcatRegisterOp>(), isEmpty);

      final restored = VasterProgramBinary.fromBytes(program.toBytes());
      expect(restored.resultBinding, equals('answer'));
      expect(VasterProgram.fromJson(program.toJson()).resultBinding, equals('answer'));
    });

    test('a fully-const pipeline with bindings still compiles', () {
      // Const-constructibility is a DX invariant — Binding must not break it.
      const result = Binding('answer');
      const pipeline = Pipeline(
        name: 'const_check',
        children: [
          Inputs({Binding('question'): 'why?'}),
          Prompt(Template([r'Answer: ', Binding('question')]), output: result),
        ],
      );
      final program = const BasicWorkflowCompiler().compile(pipeline);
      expect(program.instructions.whereType<PromptOp>().first.outputVar, equals('answer'));
    });
  });
}
