import 'package:test/test.dart';
import 'package:vaster_model_fake/vaster_model_fake.dart';
import 'package:vaster_vm/vaster_vm.dart';

void main() {
  group('VasterRuntime Engine & Complex Opcodes', () {
    late FakeVasterModel fakeModel;
    late VasterVMEngine vm;
    late VasterRuntime runtime;

    setUp(() async {
      fakeModel = FakeVasterModel(defaultResponseText: '{"status": "ok", "code": 200}');
      vm = await VasterVMEngine.bootstrap(
        config: VMConfig(
          defaultModel: fakeModel,
          rootMountPath: '/mem',
        ),
      );
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

    test('executes conditional jumping and register operations', () async {
      const program = VasterProgram(
        programName: 'jump_and_reg_test',
        instructions: [
          SetRegisterOp(registerName: 'flag', value: true),
          JumpIfOp(targetPc: 3, conditionVar: 'flag'),
          SetRegisterOp(registerName: 'skipped', value: 'should_not_run'),
          SetRegisterOp(registerName: 'landed', value: 'success'),
          HaltOp(),
        ],
      );

      final state = await runtime.executeProgram(program);

      expect(state.status, equals(RuntimeStatus.halted));
      expect(state.registers['flag'], isTrue);
      expect(state.registers['skipped'], isNull);
      expect(state.registers['landed'], equals('success'));
    });

    test('extracts JSON fields and concatenates registers', () async {
      const program = VasterProgram(
        programName: 'json_concat_test',
        instructions: [
          SetRegisterOp(registerName: 'json_raw', value: '{"status": "ok", "code": 200}'),
          JsonExtractOp(sourceVar: 'json_raw', jsonKey: 'status', targetVar: 'status_val'),
          SetRegisterOp(registerName: 'prefix', value: 'Status is: '),
          ConcatRegisterOp(targetVar: 'final_msg', sourceVars: ['prefix', 'status_val']),
          HaltOp(),
        ],
      );

      final state = await runtime.executeProgram(program);

      expect(state.status, equals(RuntimeStatus.halted));
      expect(state.registers['status_val'], equals('ok'));
      expect(state.registers['final_msg'], equals('Status is: ok'));
    });

    test('performs VFS transaction rollback on opcode instruction', () async {
      const program = VasterProgram(
        programName: 'vfs_rollback_test',
        instructions: [
          MountFsOp(mountPrefix: '/mem'),
          WriteFileOp(vfsPath: '/mem/version.txt', content: 'v1.0'),
          BeginTransactionOp(),
          WriteFileOp(vfsPath: '/mem/version.txt', content: 'v2.0_bad'),
          RollbackOp(),
          ReadFileOp(vfsPath: '/mem/version.txt', outputVar: 'v_restored'),
          HaltOp(),
        ],
      );

      final state = await runtime.executeProgram(program);

      expect(state.status, equals(RuntimeStatus.halted));
      expect(state.registers['v_restored'], equals('v1.0'));
    });

    test('creates session and routes PromptOp into session history', () async {
      const program = VasterProgram(
        programName: 'session_prompt_test',
        instructions: [
          CreateSessionOp(sessionId: 'sess_multi_turn'),
          SetSessionOp(sessionId: 'sess_multi_turn'),
          PromptOp(promptText: 'Hello Model', outputVar: 'ans1'),
          PromptOp(promptText: 'Follow up prompt', outputVar: 'ans2'),
          HaltOp(),
        ],
      );

      final state = await runtime.executeProgram(program);

      expect(state.status, equals(RuntimeStatus.halted));
      expect(state.registers['ans1'], isNotEmpty);
      expect(state.registers['ans2'], isNotEmpty);

      final session = vm.sessionManager.getSession('sess_multi_turn');
      expect(session, isNotNull);
      // 2 prompts = 4 messages (user, model, user, model)
      expect(session!.history.length, equals(4));
      expect(session.history[0].text, contains('Hello Model'));
      expect(session.history[2].text, contains('Follow up prompt'));
    });

    test('executes CheckPolicyOp successfully when operation is authorized', () async {
      const program = VasterProgram(
        programName: 'check_policy_pass_test',
        instructions: [
          CheckPolicyOp(action: PolicyAction.fileRead, resource: '/mem/data.json'),
          SetRegisterOp(registerName: 'result', value: 'authorized'),
          HaltOp(),
        ],
      );

      final state = await runtime.executeProgram(program);

      expect(state.status, equals(RuntimeStatus.halted));
      expect(state.registers['result'], equals('authorized'));
    });

    test('enforces write restriction under read-only policy engine', () async {
      // Custom VM with readOnly policy engine
      final restrictedVm = await VasterVMEngine.bootstrap(
        config: VMConfig(defaultModel: fakeModel, rootMountPath: '/mem'),
        policyEngine: BasicPolicyEngine(),
      );

      // Create runtime with restricted policy set on execution
      final restrictedRuntime = VasterRuntime(
        vm: restrictedVm,
        policy: ExecutionPolicy.readOnly,
        budget: ExecutionBudget.unlimited(),
        scheduler: BasicVasterScheduler(taskQueue: PriorityTaskQueue()),
      );

      // Program trying to write a file that gets denied by CheckPolicyOp
      const program = VasterProgram(
        programName: 'policy_denial_test',
        instructions: [
          CheckPolicyOp(action: PolicyAction.fileDelete, resource: '/sys/protected.sys'),
          WriteFileOp(vfsPath: '/mem/test.txt', content: 'hello'),
          HaltOp(),
        ],
      );

      final state = await restrictedRuntime.executeProgram(program);

      // Verify execution errored due to default-deny fallback for fileDelete
      expect(state.status, equals(RuntimeStatus.error));
      expect(state.errorDetails, contains('Policy violation'));

      await restrictedVm.shutdown();
    });

    test('executeStep halting a program prunes step-scoped context regions',
        () async {
      const program = VasterProgram(programName: 'sliced_ctx', instructions: [
        AddContextOp(regionId: 'step_region', label: 'step', text: 'x', lifetime: 'step'),
        HaltOp(),
      ]);

      // Drive to halt through the time-sliced entry point, one instruction at
      // a time, never touching executeProgram.
      var state = await runtime.executeStep(program, stepCount: 1);
      expect(state.status, equals(RuntimeStatus.running));
      expect(vm.contextManager.getRegion('step_region'), isNotNull);

      state = await runtime.executeStep(program, stepCount: 1);
      expect(state.status, equals(RuntimeStatus.halted));
      expect(vm.contextManager.getRegion('step_region'), isNull,
          reason: 'halting via a quantum must expire step-scoped regions '
              'exactly like a run to completion');
    });

    test('emits tool and sandbox telemetry on the event bus', () async {
      // Model: first turn calls the tool, continuation answers with text.
      final toolModel = FakeVasterModel(handler: (request) {
        final answered = request.messages
            .where((m) => m.role == Role.tool)
            .expand((m) => m.parts)
            .whereType<FunctionResponsePart>()
            .isNotEmpty;
        if (!answered) {
          return const ModelResponse(
            message: ChatMessage(role: Role.model, parts: [
              FunctionCallPart(callId: 'call_ping', name: 'ping', arguments: {}),
            ]),
            finishReason: FinishReason.toolCalls,
          );
        }
        return ModelResponse(message: ChatMessage.model('done'));
      });
      final vm = await VasterVMEngine.bootstrap(
          config: VMConfig(defaultModel: toolModel));
      final runtime = VasterRuntime(
        vm: vm,
        policy: ExecutionPolicy.unlimited,
        budget: ExecutionBudget.unlimited(),
        scheduler: BasicVasterScheduler(taskQueue: PriorityTaskQueue()),
      );

      final toolCalled = <ToolCalledEvent>[];
      final toolFinished = <ToolFinishedEvent>[];
      final sandboxExecuted = <SandboxExecutedEvent>[];
      vm.eventBus.on<ToolCalledEvent>().listen(toolCalled.add);
      vm.eventBus.on<ToolFinishedEvent>().listen(toolFinished.add);
      vm.eventBus.on<SandboxExecutedEvent>().listen(sandboxExecuted.add);

      vm.registerTool(FunctionTool.define(
        name: 'ping',
        description: 'Ping',
        parametersSchema: const {'type': 'object', 'properties': {}},
        handler: (_) => {'pong': true},
      ));
      vm.registerSandbox(IsolateCodeSandbox(
        descriptor: const SandboxDescriptor(
          sandboxId: 'iso_events',
          type: 'isolate',
          description: 'Event telemetry sandbox',
        ),
        evaluator: (code, inputs) => 'evaluated',
      ));

      const program = VasterProgram(programName: 'telemetry', instructions: [
        PromptOp(promptText: 'ping the tool', outputVar: 'r0'),
        ExecSandboxOp(sandboxId: 'iso_events', code: '1 + 1', outputVar: 's0'),
        HaltOp(),
      ]);

      final state = await runtime.executeProgram(program);
      expect(state.status, equals(RuntimeStatus.halted));
      await Future<void>.delayed(Duration.zero); // flush the broadcast stream

      expect(toolCalled, hasLength(1));
      expect(toolCalled.single.toolName, equals('ping'));
      expect(toolCalled.single.callId, equals('call_ping'));

      expect(toolFinished, hasLength(1));
      expect(toolFinished.single.callId, equals('call_ping'));
      expect(toolFinished.single.isError, isFalse);

      expect(sandboxExecuted, hasLength(1));
      expect(sandboxExecuted.single.sandboxId, equals('iso_events'));
      expect(sandboxExecuted.single.exitCode, equals(0));

      await vm.shutdown();
    });

    test('HITL pause inside a scheduled quantum can be resumed', () async {
      const program = VasterProgram(programName: 'sliced_hitl', instructions: [
        YieldHumanInteractionOp(
          request: HumanInteractionRequest(
            requestId: 'req_q',
            type: HumanInteractionType.approval,
            prompt: 'Continue?',
            options: ['approve', 'reject'],
            outputVar: 'answer',
          ),
        ),
        SetRegisterOp(registerName: 'after', value: 'resumed'),
        HaltOp(),
      ]);

      final paused = await runtime.executeStep(program, stepCount: 5);
      expect(paused.status, equals(RuntimeStatus.pausedForHuman));

      final resumed = await runtime.resumeWithHumanResponse(
        HumanInteractionResponse.approve(requestId: 'req_q'),
      );
      expect(resumed.status, equals(RuntimeStatus.halted));
      expect(resumed.registers['after'], equals('resumed'));
    });
  });
}
