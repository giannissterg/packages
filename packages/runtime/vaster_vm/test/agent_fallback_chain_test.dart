import 'package:test/test.dart';
import 'package:vaster_model_fake/vaster_model_fake.dart';
import 'package:vaster_vm/vaster_vm.dart';

/// GAP-3b: an agent's declared model chain is descriptor data, resolved at
/// creation, enforced at every agent turn — the agent layer gets exactly
/// the REL-P3 semantics the runtime's active model has.
void main() {
  const downDescriptor = ModelDescriptor(provider: 'agent_down', modelId: 'p');
  const upDescriptor = ModelDescriptor(provider: 'agent_up', modelId: 'f');

  Future<VasterVMEngine> boot() async {
    final vm = await VasterVMEngine.bootstrap(
        config: VMConfig(defaultModel: FakeVasterModel()));
    vm.registerModel(
      downDescriptor,
      FakeVasterModel(
          modelName: 'agent-down',
          handler: (_) => throw StateError('API error 503 down')),
    );
    vm.registerModel(
      upDescriptor,
      FakeVasterModel(
          modelName: 'agent-up', defaultResponseText: 'served by fallback'),
    );
    return vm;
  }

  test('a task on an agent with a dead primary is served by the chain',
      () async {
    final vm = await boot();
    addTearDown(vm.shutdown);

    final fallbackEvents = <ModelFallbackEvent>[];
    final turnUsageEvents = <ModelUsageEvent>[];
    final subs = [
      vm.eventBus.on<ModelFallbackEvent>().listen(fallbackEvents.add),
      vm.eventBus.on<ModelUsageEvent>().listen(turnUsageEvents.add),
    ];

    await vm.createAgent(
      descriptor: const AgentDescriptor(
        agentId: 'chained',
        name: 'Chained',
        role: 'worker',
        systemInstruction: 'Work.',
        modelDescriptor: downDescriptor,
        modelFallbacks: [upDescriptor],
      ),
    );

    final output = await vm.runAgentTask(
      AgentTask(taskId: 't1', inputPrompt: 'do the work'),
      agentId: 'chained',
    );
    for (final sub in subs) {
      await sub.cancel();
    }

    expect(output.isSuccess, isTrue, reason: output.errorDetails ?? '');
    expect(output.outputText, contains('served by fallback'));
    expect(fallbackEvents, hasLength(1));
    expect(fallbackEvents.single.fromModel, 'agent-down');
    expect(fallbackEvents.single.toModel, 'agent-up');

    // Attribution: the per-turn meter charges the SERVING member, not the
    // chain's head (the agent reads response.servedBy).
    final agentTurns =
        turnUsageEvents.where((e) => e.callSite == 'agent_turn');
    expect(agentTurns, isNotEmpty);
    expect(agentTurns.map((e) => e.modelName), everyElement('agent-up'));
  });

  test('an explicit host model overrides the descriptor chain', () async {
    final vm = await boot();
    addTearDown(vm.shutdown);

    await vm.createAgent(
      descriptor: const AgentDescriptor(
        agentId: 'overridden',
        name: 'O',
        role: 'r',
        systemInstruction: 's',
        modelDescriptor: downDescriptor,
        modelFallbacks: [upDescriptor],
      ),
      model: FakeVasterModel(
          modelName: 'host-model', defaultResponseText: 'host model spoke'),
    );

    final output = await vm.runAgentTask(
      AgentTask(taskId: 't2', inputPrompt: 'do the work'),
      agentId: 'overridden',
    );
    expect(output.outputText, contains('host model spoke'),
        reason: 'explicit model wins over the declared chain');
  });

  test('descriptor chain round-trips JSON, omitted when undeclared', () {
    const chained = AgentDescriptor(
      agentId: 'a',
      name: 'n',
      role: 'r',
      systemInstruction: 's',
      modelDescriptor: downDescriptor,
      modelFallbacks: [upDescriptor],
    );
    final restored = AgentDescriptor.fromJson(chained.toJson());
    expect(restored.modelDescriptor?.descriptorKey, 'agent_down:p');
    expect(restored.modelFallbacks.map((f) => f.descriptorKey),
        ['agent_up:f']);

    const plain = AgentDescriptor(
        agentId: 'a', name: 'n', role: 'r', systemInstruction: 's');
    expect(plain.toJson().containsKey('modelDescriptor'), isFalse);
    expect(plain.toJson().containsKey('modelFallbacks'), isFalse,
        reason: 'pre-chain descriptors stay byte-identical');
  });
}
