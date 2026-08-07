import 'package:test/test.dart';
import 'package:vaster_ast/vaster_ast.dart';
import 'package:vaster_domain/vaster_domain.dart';

// ── Test domain types for Provider<T> ─────────────────────────────────────

class DatabaseConfig {
  final String host;
  final int port;
  const DatabaseConfig({required this.host, required this.port});
}

class ServiceConfig {
  final String serviceName;
  const ServiceConfig({required this.serviceName});
}

// ── Test ComposableNode ────────────────────────────────────────────────────────

class SecurityAuditComponent extends ComposableNode {
  final String sourceFilePath;
  final String auditorRoleId;

  const SecurityAuditComponent({required this.sourceFilePath, required this.auditorRoleId});

  @override
  VasterNode build(BuildContext context) {
    return Transaction(
      children: [
        ReadFile(path: Template.text(sourceFilePath)),
        Task(
          agentId: auditorRoleId,
          prompt: Template.text('Audit $sourceFilePath for security vulnerabilities.'),
        ),
      ],
    );
  }
}

/// ComposableNode that reads a typed value from context.
class DbConnectComponent extends ComposableNode {
  const DbConnectComponent();

  @override
  VasterNode build(BuildContext context) {
    final config = context.read<DatabaseConfig>();
    return Prompt(Template.text('Connect to ${config.host}:${config.port}'));
  }
}

// ── Tests ─────────────────────────────────────────────────────────────────────

void main() {
  group('vaster_ast Nodes & ComposableNode', () {
    final spec = PipelineSpec(name: 'test_pipeline');
    final context = BuildContext(pipelineSpec: spec);

    test('Pipeline holds body nodes', () {
      const pipeline = Pipeline(
        spec: PipelineSpec(name: 'demo'),
        result: Binding('greeting'),
        children: [
          Mount(mount: StorageMount(mountPrefix: '/mem')),
          Prompt(Template.text('Hello'), output: Binding('greeting')),
        ],
      );
      expect(pipeline.children, hasLength(2));
      expect(pipeline.children.first, isA<Mount>());
      expect(pipeline.children.last, isA<Prompt>());
      expect(pipeline.result?.name, equals('greeting'));
    });

    test('BuildContext.withRole creates new context without mutating original', () {
      const role = AgentRole(
        roleId: 'eng',
        name: 'Engineer',
        title: 'Backend Dev',
        instruction: 'Write Dart code.',
      );
      final ctx2 = context.withRole(role);
      expect(ctx2.hasRole('eng'), isTrue);
      expect(context.hasRole('eng'), isFalse);
    });

    test('ComposableNode.build() expands into correct sub-tree', () {
      const component = SecurityAuditComponent(
        sourceFilePath: '/workspace/auth.dart',
        auditorRoleId: 'security_auditor',
      );

      final expanded = component.build(context);
      expect(expanded, isA<Transaction>());
      final tx = expanded as Transaction;
      expect(tx.children, hasLength(2));
      expect(tx.children.first, isA<ReadFile>());
      expect(tx.children.last, isA<Task>());
    });
  });

  group('BuildContext typed Provider API', () {
    final spec = PipelineSpec(name: 'provider_test_pipeline');
    final baseContext = BuildContext(pipelineSpec: spec);

    test('provide<T>() injects typed value and read<T>() retrieves it', () {
      const config = DatabaseConfig(host: 'db.prod.internal', port: 5432);
      final ctx = baseContext.provide<DatabaseConfig>(config);

      expect(ctx.has<DatabaseConfig>(), isTrue);
      expect(ctx.read<DatabaseConfig>().host, equals('db.prod.internal'));
      expect(ctx.read<DatabaseConfig>().port, equals(5432));
    });

    test('tryRead<T>() returns null when not provided', () {
      expect(baseContext.tryRead<DatabaseConfig>(), isNull);
    });

    test('read<T>() throws StateError when not provided', () {
      expect(() => baseContext.read<DatabaseConfig>(), throwsA(isA<StateError>()));
    });

    test('multiple typed values can coexist in BuildContext', () {
      const dbConfig = DatabaseConfig(host: 'localhost', port: 5432);
      const svcConfig = ServiceConfig(serviceName: 'auth-service');

      final ctx = baseContext.provide<DatabaseConfig>(dbConfig).provide<ServiceConfig>(svcConfig);

      expect(ctx.read<DatabaseConfig>().host, equals('localhost'));
      expect(ctx.read<ServiceConfig>().serviceName, equals('auth-service'));
    });

    test('provide<T>() does not mutate parent context', () {
      const dbConfig = DatabaseConfig(host: 'localhost', port: 5432);
      final ctx = baseContext.provide<DatabaseConfig>(dbConfig);

      expect(ctx.has<DatabaseConfig>(), isTrue);
      expect(baseContext.has<DatabaseConfig>(), isFalse);
    });

    test('ComposableNode reads typed value injected by ancestor ProviderNode', () {
      const dbConfig = DatabaseConfig(host: 'analytics.internal', port: 9000);
      final ctx = baseContext.provide<DatabaseConfig>(dbConfig);

      const component = DbConnectComponent();
      final expanded = component.build(ctx);

      expect(expanded, isA<Prompt>());
      expect((expanded as Prompt).prompt.lower(), equals('Connect to analytics.internal:9000'));
    });

    test('ProviderNode.applyToContext() injects typed value preserving T', () {
      const dbConfig = DatabaseConfig(host: 'primary.db', port: 5432);
      const provider = Provider<DatabaseConfig>(value: dbConfig, children: []);

      final enrichedContext = provider.applyToContext(baseContext);
      expect(enrichedContext.read<DatabaseConfig>().host, equals('primary.db'));
    });

    test('Builder<T> hands the context-resolved value to its subtree (AST_REVIEW F7)', () {
      const dbConfig = DatabaseConfig(host: 'primary.db', port: 5432);
      final scoped = const Provider<DatabaseConfig>(
        value: dbConfig,
        children: [],
      ).applyToContext(baseContext);

      final builder = Builder<DatabaseConfig>(
        (context, config) => Prompt(Template.text('Connect to ${config.host}')),
      );
      final expanded = builder.build(scoped);
      expect((expanded as Prompt).prompt.lower(), equals('Connect to primary.db'));
    });

    test('Review.then receives the EFFECTIVE namespaced wires (AST_REVIEW F7)', () {
      final scoped = baseContext.provide<BindingScopeData>(const BindingScopeData('checkout'));
      ReviewOutputs? seen;
      Review(
        agentId: 'reviewer',
        then: (context, outputs) {
          seen = outputs;
          return Prompt(Template(['Verdict was: ', outputs.verdict]));
        },
      ).build(scoped);
      expect(seen!.review.name, equals('checkout_review'), reason: 'namespaced by the enclosing scope');
      expect(seen!.verdict.name, equals('checkout_review_verdict'));
    });

    test('Ground expands to one ReadFile per binding, in declaration order', () {
      const ground = Ground({Binding('a'): '/p/a.md', Binding('b'): '/p/b.md'});
      final expanded = ground.build(baseContext) as Sequence;
      expect(expanded.children, hasLength(2));
      final first = expanded.children.first as ReadFile;
      expect(first.path.lower(), '/p/a.md');
      expect(first.output?.name, 'a');
    });

    test('Digest expands to ReadFile + focused summarize Task', () {
      const digest = Digest(of: '/p/big.md', output: Binding('gist'), agentId: 'summarizer', focus: 'risks');
      final expanded = digest.build(baseContext) as Sequence;
      final read = expanded.children.first as ReadFile;
      final task = expanded.children.last as Task;
      expect(read.path.lower(), '/p/big.md');
      expect(task.output?.name, 'gist');
      expect(task.prompt.lower(), contains('focus on: risks'));
      expect(task.prompt.lower(), contains('--- /p/big.md ---'));
    });

    test('Revise expands to ReadFile(current) + Author addressing the critique', () {
      const revise = Revise(
        agentId: 'engineer',
        path: '/p/lib/x.dart',
        addressing: Template(['Apply:\n', Binding('review')]),
        output: Binding('revised'),
      );
      final expanded = revise.build(baseContext) as Sequence;
      final read = expanded.children.first as ReadFile;
      expect(read.path.lower(), '/p/lib/x.dart');
      final author = expanded.children.last as Author;
      expect(author.path, '/p/lib/x.dart');
      expect(author.discipline, AuthorDiscipline.source);
      expect(author.prompt.lower(), contains('--- current /p/lib/x.dart ---'));
      expect(author.prompt.lower(), contains('\${review}'));
      expect(author.prompt.lower(), contains('\${revise_current}'));
    });

    test('Template.sections renders the labeled-blocks idiom', () {
      final t = Template.sections(
        {'pubspec.yaml': const Binding('pubspec'), 'plan.md': const Binding('plan')},
        lead: const ['Do the work.'],
      );
      expect(t.lower(), 'Do the work.\n\n--- pubspec.yaml ---\n\${pubspec}\n\n--- plan.md ---\n\${plan}');
      final noLead = Template.sections({'a': const Binding('a')});
      expect(noLead.lower(), '--- a ---\n\${a}', reason: 'no leading separator without lead parts');
    });

    test('Author expands to Task + WriteFile with the declared discipline', () {
      const author = Author(
        agentId: 'engineer',
        prompt: Template.text('Write the model.'),
        path: '/out/model.dart',
        output: Binding('code'),
        discipline: AuthorDiscipline.source,
      );
      final expanded = author.build(baseContext) as Sequence;
      final task = expanded.children.first as Task;
      expect(task.prompt.lower(), startsWith('Write the model.'));
      expect(task.prompt.lower(), contains('no markdown fences'), reason: 'source discipline appended');
      expect(task.output?.name, 'code');
      final write = expanded.children.last as WriteFile;
      expect(write.path.lower(), '/out/model.dart');
      expect(write.content.lower(), '\${code}');

      const free = Author(
        agentId: 'e',
        prompt: Template.text('p'),
        path: '/x',
        output: Binding('o'),
        discipline: AuthorDiscipline.free,
      );
      final freeTask = (free.build(baseContext) as Sequence).children.first as Task;
      expect(freeTask.prompt.lower(), 'p', reason: 'free discipline appends nothing');
    });

    test('ReadFile.at / WriteFile.at equal the Template-wrapped form (AST_REVIEW F4)', () {
      const sugar = ReadFile.at('/project/pubspec.yaml', output: Binding('pubspec'));
      const wrapped = ReadFile(path: Template.text('/project/pubspec.yaml'));
      expect(sugar.path.lower(), equals(wrapped.path.lower()));
      expect(sugar.output?.name, equals('pubspec'));

      const write = WriteFile.at('/mem/out.txt', content: Template([Binding('spec')]));
      expect(write.path.lower(), equals('/mem/out.txt'));
      expect(write.content.lower(), equals('\${spec}'));
    });
  });
}
