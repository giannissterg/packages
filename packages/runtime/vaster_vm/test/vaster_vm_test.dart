import 'package:test/test.dart';
import 'package:vaster_model_fake/vaster_model_fake.dart';
import 'package:vaster_vm/vaster_vm.dart';

void main() {
  group('VasterVMEngine Master Orchestrator', () {
    late FakeVasterModel fakeModel;
    late VasterVMEngine vm;

    setUp(() async {
      fakeModel = FakeVasterModel(defaultResponseText: 'VasterVM Master Output');
      vm = await VasterVMEngine.bootstrap(
        config: VMConfig(
          defaultModel: fakeModel,
          rootMountPath: '/mem',
        ),
      );
    });

    tearDown(() async {
      await vm.shutdown();
    });

    test('bootstraps managers and runs direct model prompt', () async {
      final response = await vm.prompt('Hello VasterVM');
      expect(response.text, contains('VasterVM Master Output'));
      expect(vm.fileSystemManager.mounts.containsKey('/mem'), isTrue);
    });

    test('automatically bridges Sandbox registration into ExecutableTool', () {
      final isolateSandbox = IsolateCodeSandbox(
        descriptor: const SandboxDescriptor(
          sandboxId: 'iso_runner',
          type: 'isolate',
          description: 'Isolate Runner',
        ),
        evaluator: (code, inputs) => 'sandboxed_eval',
      );

      vm.registerSandbox(isolateSandbox);

      expect(vm.sandboxManager.getSandbox('iso_runner'), equals(isolateSandbox));
      expect(vm.toolManager.getTool('exec_iso_runner'), isNotNull);
    });

    test('runs autonomous agent task and emits event telemetry', () async {
      final events = <RuntimeEvent>[];
      vm.eventBus.stream.listen(events.add);

      final agent = await vm.createAgent(
        descriptor: const AgentDescriptor(
          agentId: 'lead_dev',
          name: 'LeadDev',
          role: 'Architect',
          systemInstruction: 'Design software',
        ),
      );

      final output = await vm.runAgentTask(
        const AgentTask(
          taskId: 't_build',
          inputPrompt: 'Build microservice',
        ),
        agentId: agent.agentId,
      );

      expect(output.isSuccess, isTrue);
      expect(output.outputText, contains('VasterVM Master Output'));

      await Future.delayed(const Duration(milliseconds: 20));
      expect(events.whereType<ModelStartedEvent>(), isNotEmpty);
      expect(events.whereType<ModelFinishedEvent>(), isNotEmpty);
    });

    test('respects CancellationToken during prompt execution', () async {
      final cancelToken = CancellationToken()..cancel('Stop prompt');
      expect(
        () => vm.prompt('Test cancelled', model: fakeModel, cancelToken: cancelToken),
        throwsA(isA<StateError>()),
      );
    });

    test('pins context region anti-eviction in VM ContextManager', () async {
      final region = ContextRegion.text(
        id: 'pinned_spec',
        label: 'System Spec',
        role: Role.system,
        text: 'Critical Architecture Guidelines',
        isPinned: true,
      );

      vm.contextManager.heap.addRegion(region);
      final compiled = await vm.contextManager.compileContext(
        budget: const TokenBudget(
            maxContextTokens: 100, reservedOutputTokens: 20, reservedToolTokens: 0),
      );

      expect(compiled.includedRegions.map((r) => r.id), contains('pinned_spec'));
    });

    test('promptStream meters tokens from the terminal chunk usage', () async {
      final vm = await VasterVMEngine.bootstrap(
        config: VMConfig(
          defaultModel: FakeVasterModel(
            usageBuilder: (request, responseText) => const UsageMetadata(
              promptTokenCount: 80,
              candidatesTokenCount: 20,
              source: UsageSource.measured,
            ),
          ),
        ),
      );

      final before = vm.resourceTracker.consumedTokens;
      await vm.promptStream('Stream a reply.').drain<void>();

      // Charged exactly the terminal snapshot — not a per-chunk sum.
      expect(vm.resourceTracker.consumedTokens - before, equals(100));
    });
  });
}
