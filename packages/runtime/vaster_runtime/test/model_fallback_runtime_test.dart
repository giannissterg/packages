import 'package:test/test.dart';
import 'package:vaster_model_fake/vaster_model_fake.dart';
import 'package:vaster_vm/vaster_vm.dart';

/// REL-P3: a `SelectModelOp` fallback chain is compiled data, runtime
/// enforced — a model-kind failure on the active model falls through to the
/// next declared descriptor, observably (typed `ModelFallbackEvent`) and
/// with the serving model stamped for attribution.
void main() {
  group('SelectModelOp fallback chain', () {
    const primaryDescriptor = ModelDescriptor(provider: 'fake_down', modelId: 'primary');
    const backupDescriptor = ModelDescriptor(provider: 'fake_up', modelId: 'backup');

    late FakeVasterModel primary;
    late FakeVasterModel backup;
    late VasterVMEngine vm;
    late VasterRuntime runtime;

    setUp(() async {
      primary = FakeVasterModel(
        modelName: 'primary',
        handler: (req) => throw StateError('API error 500 primary down'),
      );
      backup = FakeVasterModel(modelName: 'backup', defaultResponseText: 'served by backup');
      vm = await VasterVMEngine.bootstrap(
        config: VMConfig(
          defaultModel: FakeVasterModel(defaultResponseText: 'default'),
          rootMountPath: '/mem',
        ),
      );
      vm.modelRegistry.registerModel(primaryDescriptor, primary);
      vm.modelRegistry.registerModel(backupDescriptor, backup);
      runtime = VasterRuntime(
        vm: vm,
        policy: ExecutionPolicy.unlimited,
        budget: ExecutionBudget.unlimited(),
        scheduler: BasicVasterScheduler(taskQueue: PriorityTaskQueue()),
      );
    });

    tearDown(() async {
      await vm.shutdown();
    });

    test('a model-kind failure falls through to the declared fallback', () async {
      const program = VasterProgram(
        programName: 'fallback_chain_test',
        instructions: [
          SelectModelOp(descriptor: primaryDescriptor, fallbacks: [backupDescriptor]),
          PromptOp(promptText: 'Who serves this?', outputVar: 'answer'),
          HaltOp(),
        ],
      );

      final fallbackEvents = <ModelFallbackEvent>[];
      final sub = vm.eventBus.on<ModelFallbackEvent>().listen(fallbackEvents.add);

      final state = await runtime.executeProgram(program);
      await sub.cancel();

      expect(state.status, equals(RuntimeStatus.halted));
      expect(state.registers['answer'], contains('served by backup'));
      expect(
        primary.recordedRequests,
        hasLength(1),
        reason:
            'one attempt on the primary — retry-same is Resilient\'s '
            'job, the chain only advances',
      );
      expect(backup.recordedRequests, hasLength(1));

      // The advance is observable, typed, on the bus.
      expect(fallbackEvents, hasLength(1));
      expect(fallbackEvents.single.fromModel, equals('primary'));
      expect(fallbackEvents.single.toModel, equals('backup'));
      expect(fallbackEvents.single.reason, contains('500'));
    });

    test('a healthy primary serves without touching the chain', () async {
      final healthy = FakeVasterModel(modelName: 'healthy', defaultResponseText: 'served by healthy');
      const healthyDescriptor = ModelDescriptor(provider: 'fake_healthy', modelId: 'healthy');
      vm.modelRegistry.registerModel(healthyDescriptor, healthy);

      const program = VasterProgram(
        programName: 'no_fallback_needed_test',
        instructions: [
          SelectModelOp(descriptor: healthyDescriptor, fallbacks: [backupDescriptor]),
          PromptOp(promptText: 'Who serves this?', outputVar: 'answer'),
          HaltOp(),
        ],
      );

      final state = await runtime.executeProgram(program);

      expect(state.status, equals(RuntimeStatus.halted));
      expect(state.registers['answer'], contains('served by healthy'));
      expect(backup.recordedRequests, isEmpty);
    });

    test('an exhausted chain fails with the last error — catchable upstream', () async {
      const alsoDownDescriptor = ModelDescriptor(provider: 'fake_also_down', modelId: 'backup2');
      vm.modelRegistry.registerModel(
        alsoDownDescriptor,
        FakeVasterModel(
          modelName: 'backup2',
          handler: (req) => throw StateError('API error 503 backup down too'),
        ),
      );

      const program = VasterProgram(
        programName: 'chain_exhausted_test',
        instructions: [
          SelectModelOp(descriptor: primaryDescriptor, fallbacks: [alsoDownDescriptor]),
          PushErrorHandlerOp(targetPc: 4, errorVar: 'chain_error'),
          PromptOp(promptText: 'Who serves this?', outputVar: 'answer'),
          PopErrorHandlerOp(),
          HaltOp(),
        ],
      );

      final state = await runtime.executeProgram(program);

      expect(state.status, equals(RuntimeStatus.halted));
      expect(state.registers['answer'], isNull);
      expect(
        state.registers['chain_error'].toString(),
        contains('503'),
        reason:
            'the LAST member\'s error propagates once the chain '
            'exhausts',
      );
    });
  });

  group('MachineContext fallback state (Rule 8)', () {
    test('the chain survives capture/restore', () {
      final context = MachineContext()
        ..activeModelDescriptor = const ModelDescriptor(provider: 'p', modelId: 'primary')
        ..activeModelFallbacks = const [
          ModelDescriptor(provider: 'p', modelId: 'fb1'),
          ModelDescriptor(provider: 'q', modelId: 'fb2'),
        ];

      final restored = MachineContext()..restoreState(context.captureState());

      expect(restored.activeModelFallbacks.map((f) => f.descriptorKey), equals(['p:fb1', 'q:fb2']));
    });

    test('no declared chain leaves snapshots byte-compatible', () {
      final context = MachineContext()
        ..activeModelDescriptor = const ModelDescriptor(provider: 'p', modelId: 'primary');
      expect(context.captureState().containsKey('activeModelFallbacks'), isFalse);

      final restored = MachineContext()..restoreState(context.captureState());
      expect(restored.activeModelFallbacks, isEmpty);
    });
  });
}
