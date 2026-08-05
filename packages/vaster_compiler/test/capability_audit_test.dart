import 'package:test/test.dart';
import 'package:vaster_ast/vaster_ast.dart';
import 'package:vaster_compiler/vaster_compiler.dart';
import 'package:vaster_domain/vaster_domain.dart';
import 'package:vaster_model/vaster_model.dart';

void main() {
  const compiler = BasicWorkflowCompiler();

  test('audit enumerates every capability category of a compiled pipeline', () {
    const triager = AgentRole(
        roleId: 'triager', name: 'Triager', title: 'Incident Triager',
        instruction: 'Route.');
    const sre = AgentRole(
        roleId: 'sre', name: 'SRE', title: 'Reliability Engineer',
        instruction: 'Fix.');

    final program = compiler.compile(Pipeline(
      name: 'audited',
      roles: const [triager, sre],
      mounts: const [
        StorageMount(mountPrefix: '/workspace'),
        StorageMount(
            mountPrefix: '/data',
            type: StorageMountType.disk,
            diskPath: '/tmp/audited'),
      ],
      tools: const [
        ToolDefinition(name: 'query_metrics', description: 'Query metrics'),
      ],
      model: const ModelDescriptor.fake(),
      children: const [
        BudgetScope(
          maxTokens: 50000,
          maxCost: 2.5,
          child: Sequence([
            WriteFile(path: Template.text('/workspace/brief.md'), content: Template.text('the brief')),
            ReadFile(path: Template.text('/workspace/brief.md'), output: Binding('brief')),
            WriteFile(path: Template([r'/workspace/', Binding('brief'), r'.md']), content: Template.text('dynamic')),
            Sandbox(
              env: CodeEnvironment(envId: 'ci', timeoutMs: 5000),
              child: Execute(code: Template.text('run checks'), output: Binding('checks')),
            ),
            Router(
              prompt: Template.text('Who owns this incident?'),
              routes: [
                RouteCase(
                    label: 'infra',
                    description: 'infrastructure',
                    agentId: 'sre',
                    prompt: Template.text('Investigate.')),
                RouteCase(
                    label: 'triage',
                    description: 'needs routing',
                    agentId: 'triager',
                    prompt: Template.text('Route it.')),
              ],
              defaultRoute: 'triage',
            ),
            ApprovalGate(
              requestId: 'ship_gate',
              prompt: Template.text('Ship it?'),
              onApprove: [
                SendMessage(fromId: 'triager', toId: 'sre', payload: {'go': true}),
              ],
            ),
          ]),
        ),
      ],
    ));

    final audit = CapabilityAudit.of(program);

    expect(audit.programName, equals('audited'));
    expect(audit.mounts,
        equals({'/workspace': 'memory', '/data': '/tmp/audited'}));
    expect(audit.staticWrites, contains('/workspace/brief.md'));
    expect(audit.dynamicWrites, contains(r'/workspace/${brief}.md'),
        reason: 'interpolated paths are reported as dynamic, not static');
    expect(audit.staticReads, contains('/workspace/brief.md'));
    expect(audit.tools, contains('query_metrics'));
    expect(audit.agents.keys, containsAll(['triager', 'sre']));
    expect(audit.sessions, containsAll(['sess_triager', 'sess_sre']));
    expect(audit.models, contains('fake:default'));
    expect(audit.sandboxes, equals({'ci': 'dart'}));
    expect(audit.sandboxExecutions, equals(1));

    expect(audit.decisions, hasLength(1));
    final decision = audit.decisions.single;
    expect(decision.branches.keys, containsAll(['infra', 'triage']));
    expect(decision.defaultLabel, equals('triage'));

    expect(audit.humanGates.values, contains('ship_gate'));
    expect(audit.quotas.single.maxTokenBudget, equals(50000));
    expect(audit.quotas.single.maxCostBudget, equals(2.5));
    expect(audit.messageEdges, contains('triager → sre'));

    // Round-trips as JSON and renders every section.
    final json = audit.toJson();
    expect(json['decisions'], hasLength(1));
    final pretty = audit.toPrettyString();
    expect(pretty, contains('Decision surface'));
    expect(pretty, contains('⚠ dynamic (interpolated)'));
    expect(pretty, contains('DISK /tmp/audited'));
    expect(pretty, contains('ship_gate'));
  });

  test('a fully static program reports an empty decision surface', () {
    final program = compiler.compile(Pipeline(name: 'static', children: const [
      Prompt(Template.text('just one turn')),
      Output(),
    ]));
    final audit = CapabilityAudit.of(program);
    expect(audit.decisions, isEmpty);
    expect(audit.toPrettyString(),
        contains('(none — control flow is fully static)'));
    expect(audit.sandboxes, isEmpty);
    expect(audit.humanGates, isEmpty);
  });
}
