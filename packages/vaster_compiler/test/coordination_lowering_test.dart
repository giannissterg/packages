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
}
