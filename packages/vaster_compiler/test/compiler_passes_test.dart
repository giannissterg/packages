import 'package:test/test.dart';
import 'package:vaster_ast/vaster_ast.dart';
import 'package:vaster_compiler/vaster_compiler.dart';
import 'package:vaster_domain/vaster_domain.dart';
import 'package:vaster_instruction/vaster_instruction.dart';

Pipeline _pipeline(List<VasterNode> children) => Pipeline(
      spec: const PipelineSpec(name: 'test_pipeline'),
      roles: const [],
      children: children,
    );

void main() {
  group('Label IR & control-flow assembly', () {
    test('When compiles to the canonical layout (jumpIf/else/jump/then)', () {
      final program = const BasicWorkflowCompiler().compile(_pipeline([
        const Prompt('cond producer'), // writes __auto_reg_0
        const When(
          condition: '__auto_reg_0',
          then: [WriteFile(path: '/mem/t.txt', content: 'then')],
          otherwise: [WriteFile(path: '/mem/e.txt', content: 'else')],
        ),
      ]));

      final ops = program.instructions;
      // prompt, jumpIf, else-write, jump, then-write, halt
      expect(ops[1], isA<JumpIfOp>());
      final jumpIf = ops[1] as JumpIfOp;
      expect((ops[2] as WriteFileOp).vfsPath, equals('/mem/e.txt'));
      expect(ops[3], isA<JumpOp>());
      expect((ops[4] as WriteFileOp).vfsPath, equals('/mem/t.txt'));
      // jumpIf skips to the then-block; jump skips over it to the join.
      expect(jumpIf.targetPc, equals(4));
      expect((ops[3] as JumpOp).targetPc, equals(5));
      expect(ops[5], isA<HaltOp>());
    });

    test('nested When produces correct jump targets (old emitter miscompiled this)', () {
      final program = const BasicWorkflowCompiler().compile(_pipeline([
        const Prompt('outer cond'), // __auto_reg_0
        const Prompt('inner cond'), // __auto_reg_1
        const When(
          condition: '__auto_reg_0',
          then: [
            When(
              condition: '__auto_reg_1',
              then: [WriteFile(path: '/mem/tt.txt', content: 'then-then')],
              otherwise: [WriteFile(path: '/mem/te.txt', content: 'then-else')],
            ),
          ],
          otherwise: [WriteFile(path: '/mem/e.txt', content: 'else')],
        ),
      ]));

      final ops = program.instructions;
      // Every jump target must land inside the program and, critically, the
      // inner When's targets must be program-absolute (not buffer-relative).
      for (final op in ops) {
        final target = switch (op) {
          JumpOp(:final targetPc) => targetPc,
          JumpIfOp(:final targetPc) => targetPc,
          _ => null,
        };
        if (target != null) {
          expect(target, inInclusiveRange(0, ops.length),
              reason: 'target of ${op.opcode.name} in range');
        }
      }

      // Walk the then-path: outer jumpIf -> inner jumpIf -> inner then block.
      final outerJumpIf =
          ops.whereType<JumpIfOp>().firstWhere((j) => j.conditionVar == '__auto_reg_0');
      final innerJumpIf =
          ops.whereType<JumpIfOp>().firstWhere((j) => j.conditionVar == '__auto_reg_1');
      expect(ops[outerJumpIf.targetPc], equals(innerJumpIf),
          reason: 'outer then-branch starts at the inner When');
      final innerThen = ops[innerJumpIf.targetPc];
      expect((innerThen as WriteFileOp).vfsPath, equals('/mem/tt.txt'),
          reason: 'inner then-branch must be absolute, not buffer-relative');
    });
  });

  group('Semantic analysis diagnostics', () {
    test('read-before-write and unknown agent produce warnings', () {
      const compiler = BasicWorkflowCompiler();
      final result = compiler.compileWithDiagnostics(_pipeline([
        const When(
          condition: 'never_written',
          then: [WriteFile(path: '/mem/a.txt', content: 'x')],
          otherwise: [],
        ),
        const Task(agentId: 'ghost', prompt: 'do something'),
      ]));

      expect(result.hasErrors, isFalse);
      final codes = result.diagnostics.map((d) => d.code).toSet();
      expect(codes, contains('read_before_write'));
      expect(codes, contains('unknown_agent'));
      expect(codes, contains('unknown_session'));
    });

    test('clean pipeline produces no warnings of those kinds', () {
      const architect = AgentRole(
        roleId: 'architect',
        name: 'Architect',
        title: 'Architect',
        instruction: 'Design things.',
      );
      final result = const BasicWorkflowCompiler().compileWithDiagnostics(
        Pipeline(
          spec: const PipelineSpec(name: 'clean'),
          roles: const [architect],
          children: const [
            Agent(role: architect, children: [Task(prompt: 'design the app')]),
          ],
        ),
      );
      expect(result.hasErrors, isFalse);
      final codes = result.diagnostics.map((d) => d.code).toSet();
      expect(codes.contains('read_before_write'), isFalse);
      expect(codes.contains('unknown_agent'), isFalse);
    });

    test('ProgramAnalyzer flags out-of-range jumps as errors on raw programs', () {
      const program = VasterProgram(programName: 'bad', instructions: [
        JumpOp(targetPc: 99),
        HaltOp(),
      ]);
      final diagnostics = const ProgramAnalyzer().analyze(program);
      expect(
        diagnostics.any(
            (d) => d.code == 'jump_out_of_range' && d.severity == CompileSeverity.error),
        isTrue,
      );
    });

    test('unreachable code after unconditional jump is flagged', () {
      const program = VasterProgram(programName: 'dead', instructions: [
        JumpOp(targetPc: 3),
        SetRegisterOp(registerName: 'x', value: 1), // unreachable
        SetRegisterOp(registerName: 'y', value: 2), // unreachable
        HaltOp(),
      ]);
      final diagnostics = const ProgramAnalyzer().analyze(program);
      expect(diagnostics.where((d) => d.code == 'unreachable_code'), hasLength(2));
    });
  });

  group('Typed model outputs', () {
    test('Task.outputSchema lowers into DispatchAgentTaskOp.responseSchema', () {
      const architect = AgentRole(
        roleId: 'architect',
        name: 'Architect',
        title: 'Architect',
        instruction: 'Design.',
      );
      final schema = {
        'type': 'object',
        'properties': {
          'design': {'type': 'string'},
        },
        'required': ['design'],
        'additionalProperties': false,
      };
      final program = const BasicWorkflowCompiler().compile(
        Pipeline(
          spec: const PipelineSpec(name: 'typed'),
          roles: const [architect],
          children: [
            Agent(role: architect, children: [
              Task(prompt: 'design it', outputSchema: schema),
            ]),
          ],
        ),
      );

      final dispatch = program.instructions.whereType<DispatchAgentTaskOp>().single;
      expect(dispatch.responseSchema, equals(schema));

      // Survives the ISA JSON round-trip (durable typed programs).
      final rehydrated = VasterProgram.fromJson(program.toJson());
      final dispatch2 = rehydrated.instructions.whereType<DispatchAgentTaskOp>().single;
      expect(dispatch2.responseSchema, equals(schema));
    });

    test('schema inference: JsonExtract consumers type the producing prompt', () {
      // Hand-built program exercising the instruction-level inference pass.
      const program = VasterProgram(programName: 'infer', instructions: [
        PromptOp(promptText: 'produce JSON', outputVar: 'r0'),
        JsonExtractOp(sourceVar: 'r0', jsonKey: 'title', targetVar: 't'),
        JsonExtractOp(sourceVar: 'r0', jsonKey: 'body', targetVar: 'b'),
        HaltOp(),
      ]);

      final inferred = const SchemaInferencePass().run(program.instructions);
      final prompt = inferred.whereType<PromptOp>().single;
      expect(prompt.responseSchema, isNotNull);
      expect(
        (prompt.responseSchema!['properties'] as Map).keys.toSet(),
        equals({'title', 'body'}),
      );
      expect(prompt.responseSchema!['required'], equals(['body', 'title']));
      expect(prompt.responseSchema!['additionalProperties'], isFalse);
    });

    test('explicit schema wins over inference', () {
      final explicit = {
        'type': 'object',
        'properties': {
          'x': {'type': 'integer'},
        },
        'required': ['x'],
        'additionalProperties': false,
      };
      final instructions = [
        PromptOp(promptText: 'p', outputVar: 'r0', responseSchema: explicit),
        const JsonExtractOp(sourceVar: 'r0', jsonKey: 'other', targetVar: 't'),
        const HaltOp(),
      ];
      final inferred = const SchemaInferencePass().run(instructions);
      expect((inferred[0] as PromptOp).responseSchema, equals(explicit));
    });
  });

  group('Peephole optimization', () {
    test('When with empty then collapses its no-op jump under optimize', () {
      // With an empty then-block the layout is:
      //   jumpIf cond -> THEN ; <else> ; jump JOIN ; THEN: ; JOIN: halt
      // The jump targets the very next instruction — a no-op, eliminable.
      // (With an empty *else* the jump is load-bearing: it skips the then.)
      final pipeline = _pipeline([
        const Prompt('cond'),
        const When(
          condition: '__auto_reg_0',
          then: [],
          otherwise: [WriteFile(path: '/mem/e.txt', content: 'e')],
        ),
      ]);

      final unoptimized = const BasicWorkflowCompiler().compile(pipeline);
      final optimized = const BasicWorkflowCompiler(
        options: CompilerOptions(optimize: true),
      ).compile(pipeline);

      expect(unoptimized.instructions.whereType<JumpOp>(), hasLength(1));
      expect(optimized.instructions.whereType<JumpOp>(), isEmpty);
      expect(optimized.instructions.length,
          lessThan(unoptimized.instructions.length));
      // Behavior preserved: else-write still present; jumpIf skips it when
      // the condition is truthy (target = halt).
      expect(optimized.instructions.whereType<WriteFileOp>(), hasLength(1));
      final jumpIf = optimized.instructions.whereType<JumpIfOp>().single;
      expect(optimized.instructions[jumpIf.targetPc], isA<HaltOp>());
    });
  });
}
