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
