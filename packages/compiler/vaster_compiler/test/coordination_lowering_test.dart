import 'package:test/test.dart';
import 'package:vaster_ast/vaster_ast.dart';
import 'package:vaster_compiler/vaster_compiler.dart';
import 'package:vaster_domain/vaster_domain.dart';
import 'package:vaster_instruction/vaster_instruction.dart';

void main() {
  const compiler = BasicWorkflowCompiler();

  Pipeline pipeline(List<VasterNode> children) => Pipeline(name: 'coordination_test', children: children);

  AgentRole role(String id) => AgentRole(roleId: id, name: id, title: id, instruction: 'You are $id.');

  group('AgentTeam', () {
    test('provisions each role exactly once', () {
      final program = compiler.compile(
        pipeline([
          AgentTeam(
            roles: [for (var i = 0; i < 7; i++) role('agent_$i')],
            children: const [Task(agentId: 'agent_0', prompt: Template.text('go'))],
          ),
        ]),
      );
      expect(program.instructions.whereType<CreateAgentOp>(), hasLength(7));
      expect(program.instructions.whereType<CreateSessionOp>(), hasLength(7));
    });

    test('dedups against Pipeline.roles provisioning', () {
      final shared = role('shared');
      final program = compiler.compile(
        Pipeline(
          name: 'dedup',
          roles: [shared],
          children: [
            AgentTeam(roles: [shared], children: const []),
          ],
        ),
      );
      expect(
        program.instructions.whereType<CreateAgentOp>(),
        hasLength(1),
        reason: 'the same role provisioned twice must emit once',
      );
    });
  });

  group('FanOut', () {
    test('lowers to parallel dispatch with declared outputs, then synthesize', () {
      final program = compiler.compile(
        pipeline([
          AgentTeam(
            roles: [role('a'), role('b'), role('lead')],
            children: [
              const FanOut(
                tasks: [
                  ParallelTaskEntry(agentId: 'a', prompt: 'part A', output: 'part_a'),
                  ParallelTaskEntry(agentId: 'b', prompt: 'part B', output: 'part_b'),
                ],
                synthesize: Task(
                  agentId: 'lead',
                  prompt: Template([r'Combine: ', Binding('part_a'), r' and ', Binding('part_b')]),
                  output: Binding('combined'),
                ),
              ),
            ],
          ),
        ]),
      );

      final fan = program.instructions.whereType<DispatchParallelTasksOp>().single;
      expect(fan.dispatches.map((d) => d.outputVar), equals(['part_a', 'part_b']));
      final synth = program.instructions.whereType<DispatchAgentTaskOp>().single;
      expect(synth.outputVar, equals('combined'));
      expect(synth.taskPrompt, contains(r'${part_a}'));

      // The analyzer accepts the wiring (interpolated refs are bound).
      final result = compiler.compileWithDiagnostics(
        pipeline([
          AgentTeam(
            roles: [role('a'), role('b'), role('lead')],
            children: [
              const FanOut(
                tasks: [
                  ParallelTaskEntry(agentId: 'a', prompt: 'part A', output: 'part_a'),
                  ParallelTaskEntry(agentId: 'b', prompt: 'part B', output: 'part_b'),
                ],
                synthesize: Task(
                  agentId: 'lead',
                  prompt: Template([r'Combine: ', Binding('part_a'), r' and ', Binding('part_b')]),
                ),
              ),
            ],
          ),
        ]),
      );
      expect(result.diagnostics.where((d) => d.code == 'unresolved_interpolation_ref'), isEmpty);
    });
  });

  group('RefineLoop', () {
    test('expands to a DecideLoop whose default is the accept exit', () {
      final program = compiler.compile(
        pipeline([
          AgentTeam(
            roles: [role('writer'), role('editor')],
            children: [
              const RefineLoop(
                worker: Task(
                  agentId: 'writer',
                  prompt: Template([r'Draft the post. Critique so far: ', Binding('critique')]),
                  output: Binding('draft'),
                ),
                critic: Task(
                  agentId: 'editor',
                  prompt: Template([r'Critique this draft: ', Binding('draft')]),
                  output: Binding('critique'),
                ),
                maxRounds: 4,
              ),
            ],
          ),
        ]),
      );

      final decide = program.instructions.whereType<DecideOp>().single;
      expect(decide.branches.map((b) => b.label), equals(['revise', 'accept']));
      expect(decide.defaultLabel, equals('accept'), reason: 'exhaustion must terminate through accept');
      final guard = program.instructions.whereType<CompareRegisterOp>().where((op) => op.rightValue == 4);
      expect(guard, hasLength(1));
    });
  });

  group('Router', () {
    test('lowers to one DecideOp with a task dispatch per route', () {
      final program = compiler.compile(
        pipeline([
          AgentTeam(
            roles: [role('fixer'), role('oncall')],
            children: [
              const Router(
                prompt: Template.text('Triage this incident.'),
                routes: [
                  RouteCase(
                    label: 'auto',
                    description: 'safe to auto-remediate',
                    agentId: 'fixer',
                    prompt: Template.text('Fix it.'),
                  ),
                  RouteCase(
                    label: 'page',
                    description: 'needs a human',
                    agentId: 'oncall',
                    prompt: Template.text('Investigate.'),
                  ),
                ],
                defaultRoute: 'page',
              ),
            ],
          ),
        ]),
      );

      final decide = program.instructions.whereType<DecideOp>().single;
      expect(decide.branches.map((b) => b.label), equals(['auto', 'page']));
      expect(decide.defaultLabel, equals('page'));
      expect(program.instructions.whereType<DispatchAgentTaskOp>(), hasLength(2));
    });
  });

  group('Retry', () {
    test('lowers to the canonical retry LOOP — one handler, priced guard', () {
      final program = compiler.compile(
        pipeline([
          const Resilient(
            child: ReadFile(path: Template.text('/fragile/data.txt')),
            attempts: 3,
            onExhausted: [Prompt(Template.text('report the failure'))],
          ),
        ]),
      );
      // Constant code size: ONE handler, ONE child copy, a guarded
      // back-edge — not the old O(attempts) unroll.
      expect(program.instructions.whereType<PushErrorHandlerOp>(), hasLength(1));
      expect(program.instructions.whereType<PushErrorHandlerOp>().single.errorVar, 'retry_error');
      expect(program.instructions.whereType<ReadFileOp>(), hasLength(1));
      // The guard carries the ceiling — the canonical bounded-loop shape
      // the cost analyzer prices (check multiplies by attempts).
      final guard = program.instructions.whereType<CompareRegisterOp>().singleWhere(
        (op) => op.rightValue == 3,
      );
      expect(guard.operator, 'lt');
      expect(program.instructions.whereType<IncrementRegisterOp>(), isNotEmpty);
      // REL-P4: the loop carries its effect-scope brackets — the dedup
      // window that makes retried tool calls replay instead of re-execute.
      expect(program.instructions.whereType<PushEffectScopeOp>(), hasLength(1));
      expect(program.instructions.whereType<MarkEffectRetryOp>(), hasLength(1));
      expect(program.instructions.whereType<PopEffectScopeOp>(), hasLength(1));
    });

    test('constant code size: attempts=2 and attempts=50 compile identically', () {
      int sizeFor(int attempts) => compiler
          .compile(
            pipeline([
              Resilient(
                child: const ReadFile(path: Template.text('/fragile/data.txt')),
                attempts: attempts,
              ),
            ]),
          )
          .instructions
          .length;
      expect(sizeFor(2), sizeFor(50));
    });

    test('Provider<RetryPolicy> supplies attempts; node field wins', () {
      Pipeline withPolicy({int? nodeAttempts}) => pipeline([
        Provider<RetryPolicy>(
          value: const RetryPolicy(maxAttempts: 5),
          children: [
            Resilient(
              child: const ReadFile(path: Template.text('/x')),
              attempts: nodeAttempts,
            ),
          ],
        ),
      ]);

      CompareRegisterOp guardOf(Pipeline p) => compiler
          .compile(p)
          .instructions
          .whereType<CompareRegisterOp>()
          .singleWhere((op) => op.operator == 'lt');

      expect(
        guardOf(withPolicy()).rightValue,
        5,
        reason: 'the Provider-supplied ceiling lands in the loop guard',
      );
      expect(
        guardOf(withPolicy(nodeAttempts: 2)).rightValue,
        2,
        reason: 'the node field wins over the Provider',
      );
    });
  });

  group('Sequence', () {
    test('lowers to exactly its children — no instructions of its own', () {
      final flat = compiler.compile(pipeline(const [Prompt(Template.text('a')), Prompt(Template.text('b'))]));
      final wrapped = compiler.compile(
        pipeline(const [
          Sequence([Prompt(Template.text('a')), Prompt(Template.text('b'))]),
        ]),
      );
      expect(wrapped.instructions.length, equals(flat.instructions.length));
    });
  });

  group('Knowledge', () {
    test('mounts the region before its child and unmounts after it', () {
      final program = compiler.compile(
        pipeline(const [
          Knowledge(
            label: 'Project Brief',
            text: Template.text('Build a notes app.'),
            pinned: true,
            child: Prompt(Template.text('design it')),
          ),
          Prompt(Template.text('after the scope')),
        ]),
      );
      final instructions = program.instructions;

      final addPc = instructions.indexWhere((op) => op is AddContextOp);
      final promptPc = instructions.indexWhere((op) => op is PromptOp && op.promptText == 'design it');
      final evictPc = instructions.indexWhere((op) => op is EvictContextOp);

      expect(addPc, lessThan(promptPc));
      expect(promptPc, lessThan(evictPc), reason: 'structural lifetime: mount → child → unmount');

      final add = instructions[addPc] as AddContextOp;
      expect(
        add.regionId,
        equals('knowledge_project_brief'),
        reason: 'region id derives from the label slug',
      );
      expect(add.pinned, isTrue);
      final evict = instructions[evictPc] as EvictContextOp;
      expect(evict.regionId, equals(add.regionId));
      expect(evict.force, isTrue, reason: 'scope exit unmounts even pinned regions');
    });

    test('ContextBudget compacts the heap on scope entry, before its child', () {
      final program = compiler.compile(
        pipeline(const [ContextBudget(maxTokens: 12000, child: Prompt(Template.text('long-running work')))]),
      );
      final compressPc = program.instructions.indexWhere((op) => op is CompressContextOp);
      final promptPc = program.instructions.indexWhere((op) => op is PromptOp);
      expect(compressPc, lessThan(promptPc));
      expect((program.instructions[compressPc] as CompressContextOp).targetTokens, equals(12000));
    });

    test('Produce fuses typed task, extraction, and artifact write', () {
      final program = compiler.compile(
        pipeline([
          AgentTeam(
            roles: [role('architect')],
            children: const [
              Produce(
                agentId: 'architect',
                prompt: Template.text('Design the storage layer.'),
                schema: {
                  'type': 'object',
                  'properties': {
                    'summary': {'type': 'string'},
                  },
                },
                output: Binding('design'),
                artifact: '/workspace/design.json',
                extract: {'summary': Binding('design_summary')},
              ),
            ],
          ),
        ]),
      );

      final task = program.instructions.whereType<DispatchAgentTaskOp>().single;
      expect(task.outputVar, equals('design'));
      expect(task.responseSchema, isNotNull);
      final extract = program.instructions.whereType<JsonExtractOp>().single;
      expect(extract.sourceVar, equals('design'));
      expect(extract.jsonKey, equals('summary'));
      expect(extract.targetVar, equals('design_summary'));
      final write = program.instructions.whereType<WriteFileOp>().single;
      expect(write.content, equals(r'${design}'));
    });

    test('Clarify seeds its notes and loops question → human → fold', () {
      final program = compiler.compile(
        pipeline([
          AgentTeam(
            roles: [role('analyst')],
            children: const [
              Clarify(topic: Template.text('billing requirements'), agentId: 'analyst', maxQuestions: 3),
            ],
          ),
        ]),
      );
      final instructions = program.instructions;

      // Seeded notes register so round one interpolates cleanly.
      final seed = instructions.whereType<SetRegisterOp>().firstWhere(
        (op) => op.registerName == 'clarifications',
      );
      expect('${seed.value}', contains('nothing gathered'));

      // The loop: a HITL question per round, bounded by maxQuestions.
      expect(instructions.whereType<YieldHumanInteractionOp>(), hasLength(1));
      final guard = instructions.whereType<CompareRegisterOp>().where((op) => op.rightValue == 3);
      expect(guard, hasLength(1));
      final decide = instructions.whereType<DecideOp>().single;
      expect(decide.branches.map((b) => b.label), equals(['ask', 'ready']));
      expect(decide.defaultLabel, equals('ready'));
    });

    test('Verify judges sandbox output with fail as the safe default', () {
      final program = compiler.compile(
        pipeline(const [
          Verify(
            run: Template.text('dart test'),
            envId: 'ci_box',
            onPass: [Prompt(Template.text('ship it'))],
            onFail: [Prompt(Template.text('open a fix task'))],
          ),
        ]),
      );
      final instructions = program.instructions;

      final exec = instructions.whereType<ExecSandboxOp>().single;
      expect(exec.sandboxId, equals('ci_box'));
      expect(exec.outputVar, equals('verification'));
      final write = instructions.whereType<WriteFileOp>().single;
      expect(write.vfsPath, equals('/workspace/verification.md'));
      final decide = instructions.whereType<DecideOp>().single;
      expect(decide.branches.map((b) => b.label), equals(['pass', 'fail']));
      expect(decide.defaultLabel, equals('fail'), reason: 'verification must not pass on ambiguity');
      expect(decide.outputVar, equals('verification_verdict'));

      // Each verdict branch contains its continuation.
      final passTarget = instructions[decide.branches[0].targetPc];
      expect((passTarget as PromptOp).promptText, equals('ship it'));
      final failTarget = instructions[decide.branches[1].targetPc];
      expect((failTarget as PromptOp).promptText, equals('open a fix task'));
    });

    test('id override disambiguates same-label scopes; from binds content', () {
      final program = compiler.compile(
        pipeline(const [
          Prompt(Template.text('produce the notes'), output: Binding('notes')),
          Knowledge(
            label: 'notes',
            from: Binding('notes'),
            id: 'k1',
            child: Prompt(Template.text('use them')),
          ),
        ]),
      );
      final add = program.instructions.whereType<AddContextOp>().single;
      expect(add.regionId, equals('k1'));
      expect(add.sourceVar, equals('notes'));
    });
  });
}
