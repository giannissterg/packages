import 'package:test/test.dart';
import 'package:vaster_model_fake/vaster_model_fake.dart';
import 'package:vaster_vm/vaster_vm.dart';

void main() {
  group('Tool linking — ToolManager symbol table dispatch', () {
    test('registered tool executes and result round-trips as typed tool_result',
        () async {
      var toolInvocations = 0;

      // The model: first turn emits a tool call; the continuation (which must
      // carry a typed tool_result) answers using the tool's payload.
      final fakeModel = FakeVasterModel(handler: (request) {
        final toolTurn = request.messages
            .where((m) => m.role == Role.tool)
            .expand((m) => m.parts)
            .whereType<FunctionResponsePart>()
            .firstOrNull;
        if (toolTurn == null) {
          return ModelResponse(
            message: const ChatMessage(role: Role.model, parts: [
              TextPart('Checking the price.'),
              FunctionCallPart(
                callId: 'call_1',
                name: 'get_price',
                arguments: {'symbol': 'VSTR'},
              ),
            ]),
            finishReason: FinishReason.toolCalls,
          );
        }
        return ModelResponse(
          message: ChatMessage.model(
              'The price is ${toolTurn.response['price']}.'),
        );
      });

      final vm = await VasterVMEngine.bootstrap(
          config: VMConfig(defaultModel: fakeModel));
      vm.registerTool(FunctionTool.define(
        name: 'get_price',
        description: 'Get the price for a symbol',
        parametersSchema: const {
          'type': 'object',
          'properties': {
            'symbol': {'type': 'string'},
          },
        },
        handler: (args) {
          toolInvocations++;
          expect(args['symbol'], equals('VSTR'));
          return {'price': 42.5};
        },
      ));
      final runtime = VasterRuntime(
        vm: vm,
        policy: ExecutionPolicy.unlimited,
        budget: ExecutionBudget.unlimited(),
        scheduler: BasicVasterScheduler(taskQueue: PriorityTaskQueue()),
      );

      const program = VasterProgram(programName: 'tool_link', instructions: [
        PromptOp(promptText: 'What is the price of VSTR?', outputVar: 'r0'),
        HaltOp(),
      ]);

      final state = await runtime.executeProgram(program);

      expect(state.status, equals(RuntimeStatus.halted));
      expect(toolInvocations, equals(1), reason: 'linked tool actually ran');
      expect(state.registers['r0'], contains('42.5'));

      // The continuation request must be fully typed: assistant tool_use turn
      // echoed, tool_result answered, and tool definitions attached.
      final continuation = fakeModel.recordedRequests.last;
      final assistantCalls = continuation.messages
          .where((m) => m.role == Role.model)
          .expand((m) => m.parts)
          .whereType<FunctionCallPart>();
      expect(assistantCalls.single.callId, equals('call_1'));
      final toolResponses = continuation.messages
          .where((m) => m.role == Role.tool)
          .expand((m) => m.parts)
          .whereType<FunctionResponsePart>();
      expect(toolResponses.single.response, equals({'price': 42.5}));
      expect(continuation.tools.map((t) => t.name), contains('get_price'));

      await vm.shutdown();
    });

    test('unknown tool returns a typed error payload the model can recover from',
        () async {
      final fakeModel = FakeVasterModel(handler: (request) {
        final sawToolError = request.messages
            .where((m) => m.role == Role.tool)
            .expand((m) => m.parts)
            .whereType<FunctionResponsePart>()
            .any((p) => p.response.containsKey('error'));
        if (sawToolError) {
          return ModelResponse(
              message: ChatMessage.model('Recovered without the tool.'));
        }
        return ModelResponse(
          message: const ChatMessage(role: Role.model, parts: [
            FunctionCallPart(callId: 'c1', name: 'ghost_tool', arguments: {}),
          ]),
          finishReason: FinishReason.toolCalls,
        );
      });

      final vm = await VasterVMEngine.bootstrap(
          config: VMConfig(defaultModel: fakeModel));
      final runtime = VasterRuntime(
        vm: vm,
        policy: ExecutionPolicy.unlimited,
        budget: ExecutionBudget.unlimited(),
        scheduler: BasicVasterScheduler(taskQueue: PriorityTaskQueue()),
      );

      const program = VasterProgram(programName: 'ghost', instructions: [
        PromptOp(promptText: 'use the ghost tool', outputVar: 'r0'),
        HaltOp(),
      ]);

      final state = await runtime.executeProgram(program);
      expect(state.status, equals(RuntimeStatus.halted));
      expect(state.registers['r0'], equals('Recovered without the tool.'));

      final errorPayload = fakeModel.recordedRequests.last.messages
          .where((m) => m.role == Role.tool)
          .expand((m) => m.parts)
          .whereType<FunctionResponsePart>()
          .single;
      expect(errorPayload.response['error'], contains('Unknown tool'));
      expect(errorPayload.response['error'], contains('ghost_tool'));

      await vm.shutdown();
    });

    test('built-in VFS syscalls still work and respect policy', () async {
      final fakeModel = FakeVasterModel(handler: (request) {
        final wrote = request.messages
            .where((m) => m.role == Role.tool)
            .expand((m) => m.parts)
            .whereType<FunctionResponsePart>()
            .any((p) => p.response['status'] == 'ok');
        if (wrote) {
          return ModelResponse(message: ChatMessage.model('File written.'));
        }
        return ModelResponse(
          message: const ChatMessage(role: Role.model, parts: [
            FunctionCallPart(
              callId: 'w1',
              name: 'write_file',
              arguments: {'path': '/mem/out.txt', 'content': 'linked!'},
            ),
          ]),
          finishReason: FinishReason.toolCalls,
        );
      });

      final vm = await VasterVMEngine.bootstrap(
          config: VMConfig(defaultModel: fakeModel));
      final runtime = VasterRuntime(
        vm: vm,
        policy: ExecutionPolicy.unlimited,
        budget: ExecutionBudget.unlimited(),
        scheduler: BasicVasterScheduler(taskQueue: PriorityTaskQueue()),
      );

      const program = VasterProgram(programName: 'vfs_syscall', instructions: [
        PromptOp(promptText: 'write the file', outputVar: 'r0'),
        HaltOp(),
      ]);

      final state = await runtime.executeProgram(program);
      expect(state.status, equals(RuntimeStatus.halted));

      // The syscall actually hit the VFS.
      final fs = vm.fileSystemManager.resolveFileSystem('/mem/out.txt');
      expect(await fs.readText('/mem/out.txt'), equals('linked!'));

      await vm.shutdown();
    });
  });

  test('program-registered VFS syscalls delegate to the ONE VfsSyscalls '
      'implementation — no third copy, no drifted output (A2)', () async {
    final vm = await VasterVMEngine.bootstrap(
        config: VMConfig(defaultModel: FakeVasterModel(), rootMountPath: '/mem'));
    addTearDown(vm.shutdown);
    final runtime = VasterRuntime(
      vm: vm,
      policy: ExecutionPolicy.unlimited,
      budget: ExecutionBudget.unlimited(),
      scheduler: BasicVasterScheduler(taskQueue: PriorityTaskQueue()),
    );

    const program = VasterProgram(
      programName: 'register_vfs_tools',
      instructions: [
        MountFsOp(mountPrefix: '/mem'),
        RegisterToolSetOp(tools: [
          ToolDefinition(
              name: 'write_file', description: 'w', parametersSchema: {}),
          ToolDefinition(
              name: 'read_file', description: 'r', parametersSchema: {}),
        ]),
        HaltOp(),
      ],
    );
    await runtime.executeProgram(program);

    final written = await vm.toolManager.executeCall(const FunctionCallPart(
        callId: 'c1',
        name: 'write_file',
        arguments: {'path': '/mem/a.txt', 'content': 'hello'}));
    expect(written.response, {'status': 'ok', 'path': '/mem/a.txt'},
        reason: 'the canonical VfsSyscalls shape — the drifted '
            '"Successfully wrote to" copy is gone');

    final read = await vm.toolManager.executeCall(const FunctionCallPart(
        callId: 'c2', name: 'read_file', arguments: {'path': '/mem/a.txt'}));
    expect(read.response['content'], 'hello');
  });
}
