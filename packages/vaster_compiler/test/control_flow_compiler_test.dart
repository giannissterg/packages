import 'package:test/test.dart';
import 'package:vaster_ast/vaster_ast.dart';
import 'package:vaster_compiler/vaster_compiler.dart';
import 'package:vaster_domain/vaster_domain.dart';
import 'package:vaster_instruction/vaster_instruction.dart';

void main() {
  const compiler = BasicWorkflowCompiler();

  Pipeline pipeline(List<VasterNode> children) => Pipeline(
        name: 'control_flow_test',
        children: children,
      );

  group('Repeat lowering', () {
    test('emits counter init, compare, body, increment, and back-jump', () {
      final program = compiler.compile(pipeline(const [
        Repeat(times: 3, counter: 'i', children: [Prompt('body')]),
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
        While(condition: 'go', maxIterations: 7, children: [Prompt('body')]),
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
          error: 'err',
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

  group('Decide lowering', () {
    test('branch targets land on each path; paths rejoin after the node', () {
      final program = compiler.compile(pipeline(const [
        Decide(
          prompt: 'Ship it?',
          paths: [
            DecisionPath(label: 'ship', description: 'ready to go',
                children: [Prompt('announce release')]),
            DecisionPath(label: 'hold', description: 'not yet',
                children: [Prompt('file blockers')]),
          ],
        ),
        Prompt('after join'),
      ]));
      final instructions = program.instructions;

      final decide = instructions.whereType<DecideOp>().single;
      expect(decide.prompt, 'Ship it?');
      expect(decide.branches.map((b) => b.label), equals(['ship', 'hold']));
      expect(decide.outputVar, isNotNull,
          reason: 'the chosen label is captured in a compiler-internal register');

      // Each branch target is that path's first instruction.
      final shipTarget = instructions[decide.branches[0].targetPc];
      expect((shipTarget as PromptOp).promptText, 'announce release');
      final holdTarget = instructions[decide.branches[1].targetPc];
      expect((holdTarget as PromptOp).promptText, 'file blockers');

      // Both paths flow to the join; the post-join prompt is present once.
      expect(
        instructions.whereType<PromptOp>().where((p) => p.promptText == 'after join'),
        hasLength(1),
      );
    });

    test('the chosen label flows to Output() positionally', () {
      final program = compiler.compile(pipeline(const [
        Decide(prompt: 'pick', paths: [
          DecisionPath(label: 'a', description: 'first'),
          DecisionPath(label: 'b', description: 'second'),
        ]),
        Output(),
      ]));
      final decide = program.instructions.whereType<DecideOp>().single;
      final concat = program.instructions.whereType<ConcatRegisterOp>().single;
      expect(concat.sourceVars, equals([decide.outputVar]));
    });

    test('optimize:true preserves every decide path block', () {
      const optimizing =
          BasicWorkflowCompiler(options: CompilerOptions(optimize: true));
      final program = optimizing.compile(pipeline(const [
        Decide(prompt: 'pick', paths: [
          DecisionPath(label: 'a', description: 'first',
              children: [Prompt('path a body')]),
          DecisionPath(label: 'b', description: 'second',
              children: [Prompt('path b body')]),
        ]),
      ]));

      final prompts =
          program.instructions.whereType<PromptOp>().map((p) => p.promptText);
      expect(prompts, containsAll(['path a body', 'path b body']),
          reason: 'branch blocks are only reachable through the decide — '
              'dead-code elimination must treat its targets as referenced');
    });

    test('defaultPath comes from Provider<DecisionPolicy> when unset on the node',
        () {
      final program = compiler.compile(pipeline(const [
        Provider<DecisionPolicy>(
          value: DecisionPolicy(defaultPath: 'b'),
          children: [
            Decide(prompt: 'pick', paths: [
              DecisionPath(label: 'a', description: 'first'),
              DecisionPath(label: 'b', description: 'second'),
            ]),
          ],
        ),
      ]));
      expect(program.instructions.whereType<DecideOp>().single.defaultLabel, 'b');
    });

    test('analyzer rejects duplicate labels and unknown defaults', () {
      const analyzer = ProgramAnalyzer();

      final duplicate = analyzer.analyze(const VasterProgram(
        programName: 'dup',
        instructions: [
          DecideOp(prompt: 'p', branches: [
            DecisionBranch(label: 'x', description: 'a', targetPc: 1),
            DecisionBranch(label: 'x', description: 'b', targetPc: 1),
          ]),
          HaltOp(),
        ],
      ));
      expect(duplicate.map((d) => d.code), contains('decide_duplicate_label'));

      final unknownDefault = analyzer.analyze(const VasterProgram(
        programName: 'unk',
        instructions: [
          DecideOp(prompt: 'p', defaultLabel: 'ghost', branches: [
            DecisionBranch(label: 'x', description: 'a', targetPc: 1),
          ]),
          HaltOp(),
        ],
      ));
      expect(unknownDefault.map((d) => d.code), contains('decide_unknown_default'));

      final empty = analyzer.analyze(const VasterProgram(
        programName: 'empty',
        instructions: [DecideOp(prompt: 'p', branches: []), HaltOp()],
      ));
      expect(empty.map((d) => d.code), contains('decide_no_branches'));
    });
  });

  group('DecideLoop lowering', () {
    test('continue branch is a back-edge; exhaustion routes to an exit', () {
      final program = compiler.compile(pipeline(const [
        DecideLoop(
          prompt: 'Keep going?',
          body: [Prompt('work step')],
          maxIterations: 3,
          exits: [
            DecisionPath(label: 'done', description: 'complete',
                children: [Prompt('wrap up')]),
          ],
        ),
      ]));
      final instructions = program.instructions;
      final decideIndex =
          instructions.indexWhere((inst) => inst is DecideOp);
      final decide = instructions[decideIndex] as DecideOp;

      expect(decide.branches.first.label, 'continue');
      expect(decide.branches.first.targetPc, lessThan(decideIndex),
          reason: 'continue is the loop back-edge');
      final doneBranch = decide.branches[1];
      expect(doneBranch.label, 'done');
      expect((instructions[doneBranch.targetPc] as PromptOp).promptText, 'wrap up');

      // The exhaustion guard: counter compare against maxIterations, and the
      // forced exit jumps to the first exit path, never back into the loop.
      final compare = instructions.whereType<CompareRegisterOp>().single;
      expect(compare.rightValue, 3);
      final forcedExit = instructions
          .whereType<JumpOp>()
          .any((j) => j.targetPc == doneBranch.targetPc);
      expect(forcedExit, isTrue);

      // No analyzer errors, and no unreachable_code on the exit path.
      final diagnostics = const ProgramAnalyzer().analyze(program);
      expect(diagnostics.where((d) => d.severity == CompileSeverity.error), isEmpty);
      expect(diagnostics.map((d) => d.code), isNot(contains('unreachable_code')));
    });

    test('onContinue lowers on the continue edge, before the back-jump', () {
      final program = compiler.compile(pipeline(const [
        DecideLoop(
          prompt: 'good enough?',
          body: [],
          continueLabel: 'revise',
          continueDescription: 'fix it first',
          onContinue: [Prompt('apply the fixes')],
          exits: [DecisionPath(label: 'approve', description: 'ship it')],
          defaultPath: 'approve',
          maxIterations: 3,
        ),
      ]));
      final instructions = program.instructions;
      final decideIndex = instructions.indexWhere((op) => op is DecideOp);
      final decide = instructions[decideIndex] as DecideOp;

      // The continue branch lands on the onContinue block, not the loop start.
      final continueTarget =
          decide.branches.firstWhere((b) => b.label == 'revise').targetPc;
      expect(continueTarget, greaterThan(decideIndex),
          reason: 'continue routes forward through onContinue');
      expect((instructions[continueTarget] as PromptOp).promptText,
          equals('apply the fixes'));

      // ...and onContinue jumps back into the loop (a backward jump).
      final backJump =
          instructions.skip(continueTarget).whereType<JumpOp>().first;
      expect(backJump.targetPc, lessThan(decideIndex),
          reason: 'after revising, control re-enters the loop');
    });

    test('Review(revise:) closes the loop: decide-first with regeneration', () {
      AgentRole role(String id) =>
          AgentRole(roleId: id, name: id, title: id, instruction: 'You: $id');
      final program = compiler.compile(Pipeline(
        name: 'review_loop',
        roles: [role('lead'), role('reviewer')],
        children: const [
          Specify(goal: 'a thing', agentId: 'lead'),
          Plan(agentId: 'lead'),
          Review(
            agentId: 'reviewer',
            revise: Plan(agentId: 'lead', addressing: 'review'),
            maxRounds: 2,
            onApprove: [Prompt('proceed to implementation')],
          ),
        ],
      ));
      final instructions = program.instructions;

      // Initial plan + in-loop revision plan, the latter embedding the
      // critique binding.
      final planPrompts = instructions
          .whereType<DispatchAgentTaskOp>()
          .where((op) => op.taskPrompt.contains('implementation plan'))
          .toList();
      expect(planPrompts, hasLength(2));
      expect(planPrompts.last.taskPrompt, contains(r'${review}'));

      // One decide with revise (continue) and approve (exit) branches,
      // approving by default.
      final decide = instructions.whereType<DecideOp>().single;
      expect(decide.branches.map((b) => b.label),
          containsAll(['revise', 'approve']));
      expect(decide.defaultLabel, equals('approve'));

      // No unreachable code, no errors — the loop is well-formed.
      final diagnostics = const ProgramAnalyzer().analyze(program);
      expect(diagnostics.where((d) => d.severity == CompileSeverity.error),
          isEmpty);
      expect(diagnostics.map((d) => d.code), isNot(contains('unreachable_code')));
    });

    test('Provider<DecisionPolicy> supplies maxIterations; node field wins',
        () {
      Pipeline loopWith({int? nodeMax}) => pipeline([
            Provider<DecisionPolicy>(
              value: const DecisionPolicy(maxIterations: 5),
              children: [
                DecideLoop(
                  prompt: 'go?',
                  body: const [Prompt('step')],
                  maxIterations: nodeMax,
                  exits: const [
                    DecisionPath(label: 'done', description: 'complete'),
                  ],
                ),
              ],
            ),
          ]);

      final fromPolicy = compiler.compile(loopWith());
      expect(
          fromPolicy.instructions.whereType<CompareRegisterOp>().single.rightValue,
          5);

      final fromNode = compiler.compile(loopWith(nodeMax: 2));
      expect(
          fromNode.instructions.whereType<CompareRegisterOp>().single.rightValue,
          2);
    });
  });
}
