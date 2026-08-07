import 'package:test/test.dart';
import 'package:vaster_events/vaster_events.dart';
import 'package:vaster_policy/vaster_policy.dart';
import 'package:vaster_policy_engine/vaster_policy_engine.dart';

void main() {
  group('BasicPolicyEngine Evaluation & Containment', () {
    late BasicPolicyEngine engine;
    late BasicEventBus eventBus;

    setUp(() {
      eventBus = BasicEventBus();
      engine = BasicPolicyEngine(eventBus: eventBus);
    });

    tearDown(() {
      eventBus.close();
    });

    test('explicit denial overrides explicit allowance', () {
      final policy = ExecutionPolicy(
        policyId: 'conflict_policy',
        allowedCapabilities: [Capability.glob(PolicyAction.fileWrite, '/mem/**')],
        deniedCapabilities: [Capability.exact(PolicyAction.fileWrite, '/mem/secrets.key')],
      );

      final okDecision = engine.authorize(
        policy: policy,
        action: PolicyAction.fileWrite,
        resource: '/mem/app.log',
      );
      expect(okDecision.isAllowed, isTrue);

      final deniedDecision = engine.authorize(
        policy: policy,
        action: PolicyAction.fileWrite,
        resource: '/mem/secrets.key',
      );
      expect(deniedDecision.isDenied, isTrue);
      expect(deniedDecision.reason, contains('Denied by explicit denial rule'));
    });

    test('publishes PolicyEvaluatedEvent telemetry event on authorization', () async {
      final policy = ExecutionPolicy.readOnly;
      final events = <RuntimeEvent>[];
      eventBus.stream.listen(events.add);

      engine.authorize(policy: policy, action: PolicyAction.fileWrite, resource: '/mem/test.txt');

      await Future.delayed(const Duration(milliseconds: 10));

      expect(events.length, equals(1));
      expect(events.first, isA<PolicyEvaluatedEvent>());
      final evalEvent = events.first as PolicyEvaluatedEvent;
      expect(evalEvent.action, equals('file:write'));
      expect(evalEvent.decision, equals('deny'));
    });

    test('deriveChildPolicy enforces strict hierarchical policy restriction', () {
      final parentPolicy = ExecutionPolicy(
        policyId: 'parent',
        allowedCapabilities: [
          Capability.glob(PolicyAction.fileRead, '/mem/workspace/**'),
          Capability.glob(PolicyAction.fileWrite, '/mem/workspace/build/**'),
        ],
        deniedCapabilities: [Capability.exact(PolicyAction.fileWrite, '/mem/workspace/build/locked.txt')],
        defaultAllow: false,
      );

      final requestedChildPolicy = ExecutionPolicy(
        policyId: 'child_request',
        allowedCapabilities: [
          Capability.glob(PolicyAction.fileWrite, '/mem/workspace/build/**'),
          Capability.glob(PolicyAction.fileWrite, '/etc/forbidden'), // Parent doesn't allow!
        ],
        deniedCapabilities: [Capability.exact(PolicyAction.fileWrite, '/mem/workspace/build/temp.txt')],
        defaultAllow: true, // Parent is defaultAllow: false, so child gets narrowed to false
      );

      final derived = engine.deriveChildPolicy(
        parentPolicy: parentPolicy,
        requestedChildPolicy: requestedChildPolicy,
      );

      // 1. /etc/forbidden must be excluded from child allowed capabilities
      expect(derived.allowedCapabilities.length, equals(1));
      expect(
        derived.allowedCapabilities.first.pattern,
        equals(const PathGlobResourcePattern('/mem/workspace/build/**')),
      );

      // 2. Denials must accumulate (parent's locked.txt + child's temp.txt)
      expect(derived.deniedCapabilities.length, equals(2));

      // 3. Child defaultAllow must be false because parent defaultAllow is false
      expect(derived.defaultAllow, isFalse);
    });
  });
}
