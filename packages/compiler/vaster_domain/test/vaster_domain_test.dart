import 'package:test/test.dart';
import 'package:vaster_domain/vaster_domain.dart';
import 'package:vaster_sandbox/vaster_sandbox.dart';

void main() {
  group('vaster_domain Specs', () {
    test('PipelineSpec JSON roundtrip', () {
      const spec = PipelineSpec(
        name: 'auth_service_pipeline',
        version: '2.0.0',
        rootStoragePath: '/workspace',
      );
      final json = spec.toJson();
      final restored = PipelineSpec.fromJson(json);
      expect(restored.name, equals('auth_service_pipeline'));
      expect(restored.version, equals('2.0.0'));
      expect(restored.rootStoragePath, equals('/workspace'));
    });

    test('AgentRole JSON roundtrip', () {
      const role = AgentRole(
        roleId: 'backend_engineer',
        name: 'Backend Engineer',
        title: 'Senior Dart Developer',
        instruction: 'You write clean, idiomatic Dart backend services.',
      );
      final json = role.toJson();
      final restored = AgentRole.fromJson(json);
      expect(restored.roleId, equals('backend_engineer'));
      expect(restored.title, equals('Senior Dart Developer'));
    });

    test('ParallelTaskEntry JSON roundtrip', () {
      const entry = ParallelTaskEntry(
        agentId: 'backend_engineer',
        prompt: 'Implement the authentication service.',
        output: 'auth_code',
      );
      final restored = ParallelTaskEntry.fromJson(entry.toJson());
      expect(restored.agentId, equals('backend_engineer'));
      expect(restored.prompt, equals('Implement the authentication service.'));
      expect(restored.output, equals('auth_code'));
    });

    test('StorageMount JSON roundtrip for memory and disk types', () {
      const memMount = StorageMount(mountPrefix: '/mem');
      const diskMount = StorageMount(
        mountPrefix: '/data',
        type: StorageMountType.disk,
        diskPath: '/Users/projects/vaster',
      );

      expect(StorageMount.fromJson(memMount.toJson()).type, equals(StorageMountType.memory));
      expect(StorageMount.fromJson(diskMount.toJson()).diskPath, equals('/Users/projects/vaster'));
    });

    test('StorageMount factories carry type and path (AST_REVIEW F6)', () {
      const disk = StorageMount.disk('/project', '/tmp/target');
      expect(disk.type, StorageMountType.disk);
      expect(disk.diskPath, '/tmp/target');
      expect(StorageMount.fromJson(disk.toJson()).diskPath, '/tmp/target');

      const mem = StorageMount.memory('/scratch');
      expect(mem.type, StorageMountType.memory);
      expect(mem.diskPath, isNull);
    });

    test('AgentRole display names default from roleId (AST_REVIEW F3)', () {
      const minimal = AgentRole(roleId: 'architect', instruction: 'You write specs.');
      expect(minimal.name, 'architect');
      expect(minimal.title, 'architect');
      // Round-trip keeps the derived values (serialized shape unchanged).
      expect(AgentRole.fromJson(minimal.toJson()).name, 'architect');

      const named = AgentRole(roleId: 'lead', name: 'Tech Lead', instruction: 'You plan.');
      expect(named.title, 'Tech Lead', reason: 'title falls back to name before roleId');
    });

    test('CodeEnvironment JSON roundtrip', () {
      final env = CodeEnvironment(envId: 'dart_sandbox', language: SandboxLanguage.dart, timeoutMs: 5000);
      final json = env.toJson();
      final restored = CodeEnvironment.fromJson(json);
      expect(restored.envId, equals('dart_sandbox'));
      expect(restored.timeoutMs, equals(5000));
    });
  });
}
