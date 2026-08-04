import 'package:test/test.dart';
import 'package:vaster_model_fake/vaster_model_fake.dart';
import 'package:vaster_vm/vaster_vm.dart';

/// One [ModelUsageEvent] per model call, emitted by the owning funnel.
void main() {
  const pinnedUsage = UsageMetadata(
    promptTokenCount: 300,
    candidatesTokenCount: 50,
    cacheReadTokenCount: 200,
    source: UsageSource.measured,
  );

  late VasterVMEngine vm;
  late List<ModelUsageEvent> events;

  setUp(() async {
    vm = await VasterVMEngine.bootstrap(
      config: VMConfig(
        defaultModel:
            FakeVasterModel(usageBuilder: (request, text) => pinnedUsage),
      ),
    );
    events = [];
    vm.eventBus.on<ModelUsageEvent>().listen(events.add);
  });

  Future<void> flush() => Future<void>.delayed(Duration.zero);

  test('vm.prompt emits exactly one measured usage event', () async {
    await vm.prompt('Hello.');
    await flush();

    expect(events, hasLength(1));
    final event = events.single;
    expect(event.callSite, equals('vm_prompt'));
    expect(event.totalTokenCount, equals(350));
    expect(event.estimated, isFalse);
    expect(event.usage['cacheReadTokenCount'], equals(200));
    // The fake is priced (free) in the builtin catalog → computed cost 0.
    expect(event.costUsd, equals(0.0));
  });

  test('promptStream emits exactly one usage event at stream end', () async {
    await vm.promptStream('Stream it.').drain<void>();
    await flush();

    expect(events, hasLength(1));
    expect(events.single.callSite, equals('vm_prompt'));
    expect(events.single.totalTokenCount, equals(350));
  });

  test('agent dispatch emits one agent_task usage event for the task tree',
      () async {
    await vm.createAgent(
        descriptor: const AgentDescriptor(
      agentId: 'worker',
      name: 'Worker',
      role: 'test',
      systemInstruction: 'Work.',
    ));
    await vm.runAgentTask(
      AgentTask(taskId: 't1', inputPrompt: 'Do it.'),
      agentId: 'worker',
    );
    await flush();

    final taskEvents = events.where((e) => e.callSite == 'agent_task');
    expect(taskEvents, hasLength(1));
    expect(taskEvents.single.totalTokenCount, equals(350));
    expect(taskEvents.single.estimated, isFalse);
  });
}
