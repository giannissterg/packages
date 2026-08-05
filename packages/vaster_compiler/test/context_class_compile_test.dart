import 'package:test/test.dart';
import 'package:vaster_ast/vaster_ast.dart';
import 'package:vaster_ast/primitives.dart';
import 'package:vaster_compiler/vaster_compiler.dart';
import 'package:vaster_instruction/vaster_instruction.dart';

/// Context classes are static program-header metadata, verified like symbols.
void main() {
  group('ContextClasses compilation', () {
    test('declared classes land in the program header, layered over standard',
        () {
      const pipeline = Pipeline(
        name: 'classy',
        children: [
          ContextClasses(
            classes: [
              ContextClass(
                name: 'domain_docs',
                band: 22,
                share: BudgetShare(minFraction: 0.2),
                cacheStable: true,
              ),
            ],
            child: Knowledge(
              label: 'API reference',
              text: 'GET /v1/things returns things.',
              className: 'domain_docs',
              child: Prompt('Summarize the API.'),
            ),
          ),
        ],
      );

      final result = const BasicWorkflowCompiler().compileWithDiagnostics(pipeline);
      expect(result.diagnostics.where((d) => d.severity == CompileSeverity.error),
          isEmpty);

      final header = result.program.contextClasses;
      expect(header, isNotNull, reason: 'classes are header metadata, not ops');
      final table = ContextClassTable.fromJson(header!);
      expect(table.contains('domain_docs'), isTrue);
      expect(table.resolve('domain_docs').share.minFraction, equals(0.2));
      expect(table.contains('history'), isTrue,
          reason: 'standard table remains underneath');

      final addOp = result.program.instructions
          .whereType<AddContextOp>()
          .firstWhere((op) => op.label == 'API reference');
      expect(addOp.className, equals('domain_docs'));
      expect(addOp.priority, isNull,
          reason: 'unset policy stays null — inherits from the class');
    });

    test('Knowledge defaults to the knowledge class', () {
      const pipeline = Pipeline(
        name: 'k',
        children: [
          Knowledge(
              label: 'Doc', text: 'x', child: Prompt('go')),
        ],
      );
      final result = const BasicWorkflowCompiler().compileWithDiagnostics(pipeline);
      final addOp =
          result.program.instructions.whereType<AddContextOp>().first;
      expect(addOp.className, equals('knowledge'));
    });

    test('undefined class reference is a compile error (undefined symbol)',
        () {
      const pipeline = Pipeline(
        name: 'broken',
        children: [
          AddContext(
              regionId: 'r1',
              label: 'r1',
              text: 'x',
              className: 'no_such_class'),
        ],
      );
      final result = const BasicWorkflowCompiler().compileWithDiagnostics(pipeline);
      expect(
        result.diagnostics.map((d) => d.code),
        contains('undefined_context_class'),
      );
    });

    test('header survives the VBC v2 binary round-trip', () {
      final program = VasterProgram(
        programName: 'vbc_classes',
        contextClasses: ContextClassTable.standard.withOverrides([
          const ContextClass(name: 'domain_docs', band: 22, cacheStable: true),
        ]).toJson(),
        instructions: const [HaltOp()],
      );

      final restored = VasterProgramBinary.fromBytes(program.toBytes());
      final table = ContextClassTable.fromJson(restored.contextClasses!);
      expect(table.resolve('domain_docs').cacheStable, isTrue);

      // A header-less program round-trips with a null header.
      const plain =
          VasterProgram(programName: 'plain', instructions: [HaltOp()]);
      expect(VasterProgramBinary.fromBytes(plain.toBytes()).contextClasses,
          isNull);
    });
  });
}
