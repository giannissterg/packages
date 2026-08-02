import 'package:test/test.dart';
import 'package:vaster_policy/vaster_policy.dart';

void main() {
  group('vaster_policy Domain Model & Capabilities', () {
    test('ResourcePattern matching works accurately', () {
      const exact = ExactResourcePattern('/mem/config.json');
      expect(exact.matches('/mem/config.json'), isTrue);
      expect(exact.matches('/mem/other.json'), isFalse);

      const glob = PathGlobResourcePattern('/mem/src/**');
      expect(glob.matches('/mem/src/main.dart'), isTrue);
      expect(glob.matches('/mem/src/sub/deep.dart'), isTrue);
      expect(glob.matches('/mem/test/test.dart'), isFalse);

      const prefix = PrefixResourcePattern('exec_tool_');
      expect(prefix.matches('exec_tool_git'), isTrue);
      expect(prefix.matches('exec_sandbox_dart'), isFalse);

      const any = AnyResourcePattern();
      expect(any.matches('anything'), isTrue);
    });

    test('Capability matching and JSON serialization roundtrip', () {
      final cap = Capability.glob(PolicyAction.fileWrite, '/mem/logs/**');

      expect(cap.matches(PolicyAction.fileWrite, '/mem/logs/today.txt'), isTrue);
      expect(cap.matches(PolicyAction.fileRead, '/mem/logs/today.txt'), isFalse);

      final json = cap.toJson();
      final restored = Capability.fromJson(json);

      expect(restored.action, equals(cap.action));
      expect(restored.pattern, equals(cap.pattern));
    });

    test('ExecutionPolicy JSON serialization roundtrip', () {
      final policy = ExecutionPolicy(
        policyId: 'secure_sandbox_policy',
        allowedCapabilities: [
          Capability.glob(PolicyAction.fileRead, '/mem/public/**'),
          Capability.prefix(PolicyAction.toolCall, 'tool_read_'),
        ],
        deniedCapabilities: [
          Capability.exact(PolicyAction.fileWrite, '/mem/system.config'),
        ],
        defaultAllow: false,
      );

      final json = policy.toJson();
      final restored = ExecutionPolicy.fromJson(json);

      expect(restored.policyId, equals('secure_sandbox_policy'));
      expect(restored.allowedCapabilities.length, equals(2));
      expect(restored.deniedCapabilities.length, equals(1));
      expect(restored.defaultAllow, isFalse);
    });
  });
}
