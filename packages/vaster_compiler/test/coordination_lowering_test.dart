import 'package:test/test.dart';
import 'package:vaster_ast/vaster_ast.dart';
import 'package:vaster_compiler/vaster_compiler.dart';
import 'package:vaster_domain/vaster_domain.dart';
import 'package:vaster_instruction/vaster_instruction.dart';

void main() {
  const compiler = BasicWorkflowCompiler();

  Pipeline pipeline(List<VasterNode> children) =>
      Pipeline(name: 'coordination_test', children: children);

  AgentRole role(String id) => AgentRole(
      roleId: id, name: id, title: id, instruction: 'You are $id.');

  group('AgentTeam', () {
    test('provisions each role exactly once', () {
      final program = compiler.compile(pipeline([
        AgentTeam(
          roles: [for (var i = 0; i < 7; i++) role('agent_$i')],
          children: const [Task(agentId: 'agent_0', prompt: 'go')],
        ),
      ]));
      expect(program.instructions.whereType<CreateAgentOp>(), hasLength(7));
      expect(program.instructions.whereType<CreateSessionOp>(), hasLength(7));
    });

    test('dedups against Pipeline.roles provisioning', () {
      final shared = role('shared');
      final program = compiler.compile(Pipeline(
        name: 'dedup',
        roles: [shared],
        children: [
          AgentTeam(roles: [shared], children: const []),
        ],
      ));
      expect(program.instructions.whereType<CreateAgentOp>(), hasLength(1),
          reason: 'the same role provisioned twice must emit once');
    });
  });

  group('FanOut', () {
    test('lowers to parallel dispatch with declared outputs, then synthesize',
        () {
      final program = compiler.compile(pipeline([
        AgentTeam(roles: [role('a'), role('b'), role('lead')], children: [
          const FanOut(
            tasks: [
              ParallelTaskEntry(agentId: 'a', prompt: 'part A', output: 'part_a'),
              ParallelTaskEntry(agentId: 'b', prompt: 'part B', output: 'part_b'),
            ],
            synthesize: Task(
              agentId: 'lead',
              prompt: r'Combine: ${part_a} and ${part_b}',
              output: 'combined',
            ),
          ),
        ]),
      ]));

      final fan = program.instructions.whereType<DispatchParallelTasksOp>().single;
      expect(fan.dispatches.map((d) => d.outputVar), equals(['part_a', 'part_b']));
      final synth = program.instructions.whereType<DispatchAgentTaskOp>().single;
      expect(synth.outputVar, equals('combined'));
      expect(synth.taskPrompt, contains(r'${part_a}'));

      // The analyzer accepts the wiring (interpolated refs are bound).
      final result = compiler.compileWithDiagnostics(pipeline([
        AgentTeam(roles: [role('a'), role('b'), role('lead')], children: [
          const FanOut(
            tasks: [
              ParallelTaskEntry(agentId: 'a', prompt: 'part A', output: 'part_a'),
              ParallelTaskEntry(agentId: 'b', prompt: 'part B', output: 'part_b'),
            ],
            synthesize: Task(
                agentId: 'lead', prompt: r'Combine: ${part_a} and ${part_b}'),
          ),
        ]),
      ]));
      expect(
        result.diagnostics.where((d) => d.code == 'unresolved_interpolation_ref'),
        isEmpty,
      );
    });
  });

  group('RefineLoop', () {
    test('expands to a DecideLoop whose default is the accept exit', () {
      final program = compiler.compile(pipeline([
        AgentTeam(roles: [role('writer'), role('editor')], children: [
          const RefineLoop(
            worker: Task(
                agentId: 'writer',
                prompt: r'Draft the post. Critique so far: ${critique}',
                output: 'draft'),
            critic: Task(
                agentId: 'editor',
                prompt: r'Critique this draft: ${draft}',
                output: 'critique'),
            maxRounds: 4,
          ),
        ]),
      ]));

      final decide = program.instructions.whereType<DecideOp>().single;
      expect(decide.branches.map((b) => b.label), equals(['revise', 'accept']));
      expect(decide.defaultLabel, equals('accept'),
          reason: 'exhaustion must terminate through accept');
      final guard = program.instructions
          .whereType<CompareRegisterOp>()
          .where((op) => op.rightValue == 4);
      expect(guard, hasLength(1));
    });
  });

  group('Router', () {
    test('lowers to one DecideOp with a task dispatch per route', () {
      final program = compiler.compile(pipeline([
        AgentTeam(roles: [role('fixer'), role('oncall')], children: [
          const Router(
            prompt: 'Triage this incident.',
            routes: [
              RouteCase(
                  label: 'auto',
                  description: 'safe to auto-remediate',
                  agentId: 'fixer',
                  prompt: 'Fix it.'),
              RouteCase(
                  label: 'page',
                  description: 'needs a human',
                  agentId: 'oncall',
                  prompt: 'Investigate.'),
            ],
            defaultRoute: 'page',
          ),
        ]),
      ]));

      final decide = program.instructions.whereType<DecideOp>().single;
      expect(decide.branches.map((b) => b.label), equals(['auto', 'page']));
      expect(decide.defaultLabel, equals('page'));
      expect(program.instructions.whereType<DispatchAgentTaskOp>(), hasLength(2));
    });
  });

  group('Retry', () {
    test('unrolls into nested handlers, one per attempt', () {
      final program = compiler.compile(pipeline([
        const Resilient(
          child: ReadFile(path: '/fragile/data.txt'),
          attempts: 3,
          onExhausted: [Prompt('report the failure')],
        ),
      ]));
      expect(program.instructions.whereType<PushErrorHandlerOp>(), hasLength(3));
      expect(
        program.instructions
            .whereType<PushErrorHandlerOp>()
            .map((op) => op.errorVar),
        containsAll(['retry_error_1', 'retry_error_2', 'retry_error_3']),
      );
      expect(program.instructions.whereType<ReadFileOp>(), hasLength(3));
    });

    test('Provider<RetryPolicy> supplies attempts; node field wins', () {
      Pipeline withPolicy({int? nodeAttempts}) => pipeline([
            Provider<RetryPolicy>(
              value: const RetryPolicy(maxAttempts: 5),
              children: [
                Resilient(
                  child: const ReadFile(path: '/x'),
                  attempts: nodeAttempts,
                ),
              ],
            ),
          ]);

      expect(
        compiler
            .compile(withPolicy())
            .instructions
            .whereType<PushErrorHandlerOp>(),
        hasLength(5),
      );
      expect(
        compiler
            .compile(withPolicy(nodeAttempts: 2))
            .instructions
            .whereType<PushErrorHandlerOp>(),
        hasLength(2),
      );
    });
  });

  group('Sequence', () {
    test('lowers to exactly its children — no instructions of its own', () {
      final flat = compiler.compile(pipeline(const [
        Prompt('a'),
        Prompt('b'),
      ]));
      final wrapped = compiler.compile(pipeline(const [
        Sequence([Prompt('a'), Prompt('b')]),
      ]));
      expect(wrapped.instructions.length, equals(flat.instructions.length));
    });
  });

  group('Knowledge', () {
    test('mounts the region before its child and unmounts after it', () {
      final program = compiler.compile(pipeline(const [
        Knowledge(
          label: 'Project Brief',
          text: 'Build a notes app.',
          pinned: true,
          child: Prompt('design it'),
        ),
        Prompt('after the scope'),
      ]));
      final instructions = program.instructions;

      final addPc = instructions.indexWhere((op) => op is AddContextOp);
      final promptPc = instructions.indexWhere(
          (op) => op is PromptOp && op.promptText == 'design it');
      final evictPc = instructions.indexWhere((op) => op is EvictContextOp);

      expect(addPc, lessThan(promptPc));
      expect(promptPc, lessThan(evictPc),
          reason: 'structural lifetime: mount → child → unmount');

      final add = instructions[addPc] as AddContextOp;
      expect(add.regionId, equals('knowledge_project_brief'),
          reason: 'region id derives from the label slug');
      expect(add.pinned, isTrue);
      final evict = instructions[evictPc] as EvictContextOp;
      expect(evict.regionId, equals(add.regionId));
      expect(evict.force, isTrue,
          reason: 'scope exit unmounts even pinned regions');
    });

    test('ContextBudget compacts the heap on scope entry, before its child', () {
      final program = compiler.compile(pipeline(const [
        ContextBudget(
          maxTokens: 12000,
          child: Prompt('long-running work'),
        ),
      ]));
      final compressPc =
          program.instructions.indexWhere((op) => op is CompressContextOp);
      final promptPc =
          program.instructions.indexWhere((op) => op is PromptOp);
      expect(compressPc, lessThan(promptPc));
      expect(
          (program.instructions[compressPc] as CompressContextOp).targetTokens,
          equals(12000));
    });

    test('Produce fuses typed task, extraction, and artifact write', () {
      final program = compiler.compile(pipeline([
        AgentTeam(roles: [role('architect')], children: const [
          Produce(
            agentId: 'architect',
            prompt: 'Design the storage layer.',
            schema: {
              'type': 'object',
              'properties': {
                'summary': {'type': 'string'},
              },
            },
            output: 'design',
            artifact: '/workspace/design.json',
            extract: {'summary': 'design_summary'},
          ),
        ]),
      ]));

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
      final program = compiler.compile(pipeline([
        AgentTeam(roles: [role('analyst')], children: const [
          Clarify(topic: 'billing requirements', agentId: 'analyst',
              maxQuestions: 3),
        ]),
      ]));
      final instructions = program.instructions;

      // Seeded notes register so round one interpolates cleanly.
      final seed = instructions
          .whereType<SetRegisterOp>()
          .firstWhere((op) => op.registerName == 'clarifications');
      expect('${seed.value}', contains('nothing gathered'));

      // The loop: a HITL question per round, bounded by maxQuestions.
      expect(instructions.whereType<YieldHumanInteractionOp>(), hasLength(1));
      final guard = instructions
          .whereType<CompareRegisterOp>()
          .where((op) => op.rightValue == 3);
      expect(guard, hasLength(1));
      final decide = instructions.whereType<DecideOp>().single;
      expect(decide.branches.map((b) => b.label), equals(['ask', 'ready']));
      expect(decide.defaultLabel, equals('ready'));
    });

    test('Verify judges sandbox output with fail as the safe default', () {
      final program = compiler.compile(pipeline(const [
        Verify(
          run: 'dart test',
          envId: 'ci_box',
          onPass: [Prompt('ship it')],
          onFail: [Prompt('open a fix task')],
        ),
      ]));
      final instructions = program.instructions;

      final exec = instructions.whereType<ExecSandboxOp>().single;
      expect(exec.sandboxId, equals('ci_box'));
      expect(exec.outputVar, equals('verification'));
      final write = instructions.whereType<WriteFileOp>().single;
      expect(write.vfsPath, equals('/workspace/verification.md'));
      final decide = instructions.whereType<DecideOp>().single;
      expect(decide.branches.map((b) => b.label), equals(['pass', 'fail']));
      expect(decide.defaultLabel, equals('fail'),
          reason: 'verification must not pass on ambiguity');
      expect(decide.outputVar, equals('verification_verdict'));

      // Each verdict branch contains its continuation.
      final passTarget = instructions[decide.branches[0].targetPc];
      expect((passTarget as PromptOp).promptText, equals('ship it'));
      final failTarget = instructions[decide.branches[1].targetPc];
      expect((failTarget as PromptOp).promptText, equals('open a fix task'));
    });

    test('id override disambiguates same-label scopes; from binds content', () {
      final program = compiler.compile(pipeline(const [
        Prompt('produce the notes', output: 'notes'),
        Knowledge(
          label: 'notes',
          from: 'notes',
          id: 'k1',
          child: Prompt('use them'),
        ),
      ]));
      final add = program.instructions.whereType<AddContextOp>().single;
      expect(add.regionId, equals('k1'));
      expect(add.sourceVar, equals('notes'));
    });
  });
}
