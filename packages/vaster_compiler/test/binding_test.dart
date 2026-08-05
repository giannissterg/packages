import 'package:test/test.dart';
import 'package:vaster_ast/vaster_ast.dart';
import 'package:vaster_compiler/vaster_compiler.dart';
import 'package:vaster_instruction/vaster_instruction.dart';

void main() {
  group('Binding', () {
    test('compiles away to its register name', () {
      const spec = Binding('spec');
      const pipeline = Pipeline(name: 'b', children: [
        Prompt('Write the spec.', output: spec),
      ]);
      final program = const BasicWorkflowCompiler().compile(pipeline);
      final op = program.instructions.whereType<PromptOp>().first;
      expect(op.outputVar, equals('spec'));
    });

    test('reserved __ prefix is a compile error', () {
      const pipeline = Pipeline(name: 'r', children: [
        Prompt('x', output: Binding('__sneaky')),
      ]);
      final result =
          const BasicWorkflowCompiler().compileWithDiagnostics(pipeline);
      expect(result.diagnostics.map((d) => d.code), contains('reserved_binding'));
    });

    test('the name is the wire: same-named bindings hit the same register',
        () {
      // Object identity is irrelevant — two distinct Binding('x') instances
      // compile to one register (identity equality keeps Binding legal as a
      // const map key in Inputs).
      final program = const BasicWorkflowCompiler().compile(const Pipeline(
        name: 'wire',
        children: [
          Prompt('produce', output: Binding('x')),
          Prompt(r'consume ${x}', output: Binding('y')),
        ],
      ));
      final ops = program.instructions.whereType<PromptOp>().toList();
      expect(ops[0].outputVar, equals('x'));
      expect(ops[1].promptText, contains(r'${x}'));

      expect(const Binding('spec').inNamespace('checkout').name,
          equals('checkout_spec'));
      expect(const Binding('spec').inNamespace('').name, equals('spec'));
    });

    test('a fully-const pipeline with bindings still compiles', () {
      // Const-constructibility is a DX invariant — Binding must not break it.
      const result = Binding('answer');
      const pipeline = Pipeline(name: 'const_check', children: [
        Inputs({Binding('question'): 'why?'}),
        Prompt(r'Answer: ${question}', output: result),
      ]);
      final program = const BasicWorkflowCompiler().compile(pipeline);
      expect(program.instructions.whereType<PromptOp>().first.outputVar,
          equals('answer'));
    });
  });
}
