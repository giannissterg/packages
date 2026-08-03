import 'package:test/test.dart';
import 'package:vaster_model_fake/vaster_model_fake.dart';
import 'package:vaster_vm/vaster_vm.dart';

void main() {
  group('ExecutionTracer', () {
    late VasterVirtualMachine vm;
    late VasterRuntime runtime;

    setUp(() async {
      vm = await VasterVMEngine.bootstrap(
          config: VMConfig(defaultModel: FakeVasterModel()));
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

    test('emits one disassembly line per instruction with register deltas',
        () async {
      final lines = <String>[];
      final tracer = ExecutionTracer(runtime, sink: lines.add)..attach();

      const program = VasterProgram(programName: 'trace_demo', instructions: [
        SetRegisterOp(registerName: 'greeting', value: 'hello'),
        PromptOp(promptText: 'say hi', outputVar: 'r0'),
        HaltOp(),
      ]);
      await runtime.executeProgram(program);
      tracer.detach();

      final opLines = lines.where((l) => l.startsWith('[')).toList();
      expect(opLines, hasLength(3));
      expect(opLines[0], contains('[0000] set_register'));
      expect(opLines[0], contains('registerName=greeting'));
      expect(opLines[1], contains('[0001] prompt'));
      expect(opLines[1], contains('+'), reason: 'prompt line shows token spend');
      expect(opLines[2], contains('[0002] halt'));

      // Register deltas rendered beneath the writing instructions.
      expect(lines.any((l) => l.contains('Δ greeting = "hello"')), isTrue);
      expect(lines.any((l) => l.contains('Δ r0 = ')), isTrue);

      // Detach restored the observer slot.
      expect(runtime.stepObserver, isNull);
    });

    test('chains a previously attached observer instead of clobbering it',
        () async {
      final observed = <int>[];
      runtime.stepObserver = (pc, inst, regs) => observed.add(pc);

      final lines = <String>[];
      final tracer = ExecutionTracer(runtime, sink: lines.add)..attach();

      const program = VasterProgram(programName: 'chain', instructions: [
        SetRegisterOp(registerName: 'x', value: 1),
        HaltOp(),
      ]);
      await runtime.executeProgram(program);

      expect(lines.where((l) => l.startsWith('[')), hasLength(2));
      expect(observed, equals([0, 1]), reason: 'chained observer still fires');

      tracer.detach();
      expect(runtime.stepObserver, isNotNull,
          reason: 'detach restores the prior observer');
    });
  });

  group('VFS syscall tools registered at bootstrap', () {
    test('write_file/read_file are advertised in the tool table and executable',
        () async {
      final vm = await VasterVMEngine.bootstrap(
          config: VMConfig(defaultModel: FakeVasterModel()));

      final names = vm.toolManager.compiledDefinitions.map((d) => d.name).toSet();
      expect(names, containsAll(['write_file', 'read_file']));

      // Executable through the symbol table (the agent/tool-manager path).
      final writeResult = await vm.toolManager.executeCall(const FunctionCallPart(
        callId: 'c1',
        name: 'write_file',
        arguments: {'path': '/mem/via_tool.txt', 'content': 'from tool table'},
      ));
      expect(writeResult.isError, isFalse);

      final readResult = await vm.toolManager.executeCall(const FunctionCallPart(
        callId: 'c2',
        name: 'read_file',
        arguments: {'path': '/mem/via_tool.txt'},
      ));
      expect(readResult.response['content'], equals('from tool table'));

      await vm.shutdown();
    });

    test('read-only policy still traps write_file through the tool loop',
        () async {
      // Policy allows the toolCall + fileRead actions but denies fileWrite —
      // the built-in syscall precedence must enforce it even though a
      // registered write_file tool exists in the table.
      final policy = ExecutionPolicy(
        policyId: 'tools_readonly',
        allowedCapabilities: [
          Capability.any(PolicyAction.toolCall),
          Capability.any(PolicyAction.fileRead),
          Capability.any(PolicyAction.modelGenerate),
        ],
        deniedCapabilities: [
          Capability.any(PolicyAction.fileWrite),
        ],
        defaultAllow: false,
      );

      final fakeModel = FakeVasterModel(handler: (request) {
        final answered =
            request.messages.any((m) => m.role == Role.tool);
        if (answered) {
          return ModelResponse(message: ChatMessage.model('done'));
        }
        return ModelResponse(
          message: const ChatMessage(role: Role.model, parts: [
            FunctionCallPart(
              callId: 'w1',
              name: 'write_file',
              arguments: {'path': '/mem/blocked.txt', 'content': 'nope'},
            ),
          ]),
          finishReason: FinishReason.toolCalls,
        );
      });

      final vm = await VasterVMEngine.bootstrap(
          config: VMConfig(defaultModel: fakeModel));
      final runtime = VasterRuntime(
        vm: vm,
        policy: policy,
        budget: ExecutionBudget.unlimited(),
        scheduler: BasicVasterScheduler(taskQueue: PriorityTaskQueue()),
      );

      const program = VasterProgram(programName: 'blocked', instructions: [
        PromptOp(promptText: 'write it', outputVar: 'r0'),
        HaltOp(),
      ]);

      final state = await runtime.executeProgram(program);
      expect(state.status, equals(RuntimeStatus.error));
      expect(state.errorDetails, contains('Policy violation'));

      // And the file was never written.
      final fs = vm.fileSystemManager.resolveFileSystem('/mem/blocked.txt');
      expect(() => fs.readText('/mem/blocked.txt'), throwsA(anything));

      await vm.shutdown();
    });
  });
}
