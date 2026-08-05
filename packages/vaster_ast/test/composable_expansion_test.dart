import 'package:test/test.dart';
import 'package:vaster_ast/primitives.dart';
import 'package:vaster_ast/vaster_ast.dart';
import 'package:vaster_domain/vaster_domain.dart';

/// Direct `build()` expansion tests for the composable tier — the package's
/// own contract, independent of compiler lowering and playground E2E
/// (backlog #9: this layer is what consumers touch most).
void main() {
  final context = BuildContext(pipelineSpec: PipelineSpec(name: 't'));

  group('Context composables', () {
    test('Knowledge expands to scoped add → child → forced evict', () {
      const node = Knowledge(
        label: 'API Docs',
        text: Template.text('The API returns things.'),
        child: Prompt(Template.text('use it')),
      );
      final expanded = node.build(context) as Sequence;

      final add = expanded.children.first as AddContext;
      expect(add.className, equals('knowledge'));
      expect(add.regionId, equals('knowledge_api_docs'));
      expect(add.priority, isNull, reason: 'inherits from the class');
      expect(expanded.children[1], isA<Prompt>());
      final evict = expanded.children.last as EvictContext;
      expect(evict.regionId, equals(add.regionId));
      expect(evict.force, isTrue,
          reason: 'scope exit evicts even pinned regions');
    });

    test('ContextBudget expands to compact-on-entry', () {
      const node = ContextBudget(
          maxTokens: 9000, child: Prompt(Template.text('go')));
      final expanded = node.build(context) as Sequence;
      final compress = expanded.children.first as CompressContext;
      expect(compress.targetTokens, equals(9000));
      expect(expanded.children.last, isA<Prompt>());
    });
  });

  group('Coordination composables', () {
    test('ApprovalGate expands to yield + status-conditioned When', () {
      const node = ApprovalGate(
        requestId: 'ship',
        prompt: Template.text('Ship it?'),
        onApprove: [Prompt(Template.text('shipping'))],
        onReject: [Prompt(Template.text('holding'))],
      );
      final tx = node.build(context) as Transaction;
      final yieldHuman = tx.children.first as YieldHuman;
      expect(yieldHuman.interactionType, equals('approval'));
      expect(yieldHuman.output, equals('ship'));
      final when = tx.children.last as When;
      final cond = when.condition as CondIsTrue;
      expect(cond.binding.name, equals('ship_status'));
      expect(when.then, hasLength(1));
      expect(when.otherwise, hasLength(1));
    });

    test('Resilient expands to nested TryCatch, innermost first', () {
      const node = Resilient(
        child: Prompt(Template.text('flaky')),
        attempts: 3,
        onExhausted: [Prompt(Template.text('give up'))],
      );
      var tree = node.build(context);
      var depth = 0;
      while (tree is TryCatch) {
        depth++;
        expect(tree.tryChildren.single, isA<Prompt>());
        tree = tree.catchChildren.single;
      }
      expect(depth, equals(3));
      expect((tree as Sequence).children.single, isA<Prompt>(),
          reason: 'exhaustion tail runs onExhausted');
    });

    test('Router expands to Decide with one Task per route', () {
      const node = Router(
        prompt: Template.text('who owns this?'),
        defaultRoute: 'triage',
        routes: [
          RouteCase(
              label: 'infra',
              description: 'infrastructure',
              agentId: 'sre',
              prompt: Template.text('investigate')),
          RouteCase(
              label: 'triage',
              description: 'route it',
              agentId: 'triager',
              prompt: Template.text('route')),
        ],
      );
      final decide = node.build(context) as Decide;
      expect(decide.defaultPath, equals('triage'));
      expect(decide.paths.map((p) => p.label), equals(['infra', 'triage']));
      final task = decide.paths.first.children.single as Task;
      expect(task.agentId, equals('sre'));
    });

    test('Produce expands to schema task → extracts → artifact write', () {
      const node = Produce(
        agentId: 'architect',
        prompt: Template.text('design it'),
        schema: {'type': 'object'},
        output: Binding('design'),
        artifact: '/workspace/design.json',
        extract: {'summary': Binding('design_summary')},
      );
      final expanded = node.build(context) as Sequence;
      final task = expanded.children.first as Task;
      expect(task.outputSchema, isNotNull);
      expect(task.output?.name, equals('design'));
      final extract = expanded.children[1] as Extract;
      expect(extract.field, equals('summary'));
      expect(extract.output.name, equals('design_summary'));
      final write = expanded.children.last as WriteFile;
      expect(write.content.parts.single, isA<Binding>());
    });

    test('FanOut expands to ParallelTasks plus optional synthesize', () {
      const node = FanOut(
        tasks: [ParallelTaskEntry(agentId: 'a', prompt: 'p1', output: 'r1')],
        synthesize: Prompt(Template.text('merge')),
      );
      final expanded = node.build(context) as Sequence;
      expect((expanded.children.first as ParallelTasks).entries, hasLength(1));
      expect(expanded.children.last, isA<Prompt>());
    });
  });

  group('Scope-provided bindings', () {
    test('BindingScope namespaces defaults; nesting composes', () {
      const scope = BindingScope(
          namespace: 'outer', child: Prompt(Template.text('x')));
      final provider = scope.build(context) as Provider<BindingScopeData>;
      expect(provider.value.namespace, equals('outer'));

      final innerContext =
          context.provide<BindingScopeData>(const BindingScopeData('outer'));
      const inner = BindingScope(
          namespace: 'inner', child: Prompt(Template.text('y')));
      final innerProvider =
          inner.build(innerContext) as Provider<BindingScopeData>;
      expect(innerProvider.value.namespace, equals('outer_inner'));

      expect(innerContext.scopedBinding('spec').name, equals('outer_spec'));
      expect(context.scopedBinding('spec').name, equals('spec'));
    });

    test('SDD Specify mints scoped defaults and honors overrides', () {
      final scoped =
          context.provide<BindingScopeData>(const BindingScopeData('auth'));
      const phase = Specify(goal: 'do it');
      final expanded = phase.build(scoped) as Sequence;
      final task = expanded.children.first as Task;
      expect(task.output?.name, equals('auth_spec'));
      final write = expanded.children.last as WriteFile;
      expect(write.path.lower(), equals('/workspace/auth_spec.md'));

      const overridden = Specify(goal: 'do it', output: Binding('my_spec'));
      final task2 =
          (overridden.build(scoped) as Sequence).children.first as Task;
      expect(task2.output?.name, equals('my_spec'),
          reason: 'explicit bindings always win over scoped defaults');
    });
  });
}
