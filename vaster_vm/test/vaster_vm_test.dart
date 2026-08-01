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
  });
}
