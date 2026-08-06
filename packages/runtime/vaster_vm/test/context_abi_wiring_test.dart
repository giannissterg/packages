import 'package:test/test.dart';
import 'package:vaster_model_fake/vaster_model_fake.dart';
import 'package:vaster_vm/vaster_vm.dart';

/// Model-ABI wiring for the context class system: the system-instruction
/// slot is fed from the heap's system class, and cache hints survive the
/// session path.
void main() {
  test('agent systemInstruction reaches ModelRequest via the system class',
      () async {
    final fake = FakeVasterModel();
    final vm = await VasterVMEngine.bootstrap(
        config: VMConfig(defaultModel: fake));

    await vm.createAgent(
        descriptor: const AgentDescriptor(
      agentId: 'writer',
      name: 'Writer',
      role: 'writes',
      systemInstruction: 'You write precise, reviewable specifications.',
    ));
    await vm.runAgentTask(
      AgentTask(taskId: 't1', inputPrompt: 'Write a spec.'),
      agentId: 'writer',
    );

    // Before the projection fix, systemInstruction never left the descriptor
    // and every agent request shipped with a null system slot.
    final request = fake.recordedRequests.last;
    expect(request.systemInstruction, isNotNull);
    expect(request.systemInstruction!.text,
        contains('precise, reviewable specifications'));
  });

  test('promptInSession forwards cache hints to the ModelRequest', () async {
    final fake = FakeVasterModel();
    final vm = await VasterVMEngine.bootstrap(
        config: VMConfig(defaultModel: fake));

    final hints = [
      const ContextCacheHint(
          regionId: 'r1', contentFingerprint: 'abc123', ttl: Duration(hours: 1)),
    ];
    await vm.promptInSession('sess_hints', 'hello', cacheHints: hints);

    // Before the forwarding fix this path silently dropped every hint.
    final request = fake.recordedRequests.last;
    expect(request.cacheHints, hasLength(1));
    expect(request.cacheHints.first.regionId, equals('r1'));
  });
}
