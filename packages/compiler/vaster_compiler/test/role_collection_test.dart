import 'package:test/test.dart';
import 'package:vaster_ast/vaster_ast.dart';
import 'package:vaster_compiler/vaster_compiler.dart';
import 'package:vaster_domain/vaster_domain.dart';
import 'package:vaster_instruction/vaster_instruction.dart';

/// F2 (AST_REVIEW): the tree already names its roles — the compiler
/// collects every `agent:`-referenced AgentRole from the WHOLE subtree and
/// provisions it at the slot Pipeline reserves. `roles:` remains only for
/// roles the tree cannot see (agentId: string references).
void main() {
  const compiler = BasicWorkflowCompiler();
  const architect = AgentRole(roleId: 'architect', instruction: 'You write specs.');
  const lead = AgentRole(roleId: 'lead', instruction: 'You plan.');

  test('roles named via agent: provision without a roles: list', () {
    final program = compiler.compile(
      const Pipeline(
        name: 'collected',
        children: [
          Specify(goal: Template.text('a thing'), agent: architect),
          Plan(agent: lead),
        ],
      ),
    );

    final created = program.instructions.whereType<CreateAgentOp>().toList();
    expect(created.map((op) => op.descriptor.agentId), containsAll(['architect', 'lead']));

    // Provisioning precedes the first dispatch that names the agent.
    final firstCreate = program.instructions.indexWhere((i) => i is CreateAgentOp);
    final firstDispatch = program.instructions.indexWhere((i) => i is DispatchAgentTaskOp);
    expect(firstCreate, lessThan(firstDispatch));
  });

  test('one role, many tasks: provisioned exactly once (subtree-wide dedup)', () {
    final program = compiler.compile(
      const Pipeline(
        name: 'dedup',
        children: [
          Task(agent: architect, prompt: Template.text('one')),
          Task(agent: architect, prompt: Template.text('two')),
        ],
      ),
    );
    expect(program.instructions.whereType<CreateAgentOp>(), hasLength(1));
  });

  test('explicit roles: overlapping with agent: references never double-provisions', () {
    final program = compiler.compile(
      const Pipeline(
        name: 'overlap',
        roles: [architect],
        children: [Task(agent: architect, prompt: Template.text('go'))],
      ),
    );
    expect(program.instructions.whereType<CreateAgentOp>(), hasLength(1));
  });

  test('one roleId, two definitions is a compile error', () {
    const impostor = AgentRole(roleId: 'architect', instruction: 'You do something else entirely.');
    final result = compiler.compileWithDiagnostics(
      const Pipeline(
        name: 'conflict',
        children: [
          Task(agent: architect, prompt: Template.text('one')),
          Task(agent: impostor, prompt: Template.text('two')),
        ],
      ),
    );
    expect(result.errors.map((d) => d.code), contains('conflicting_agent_role'));
  });
}
