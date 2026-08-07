import 'package:test/test.dart';
import 'package:vaster_model_fake/vaster_model_fake.dart';
import 'package:vaster_vm/vaster_vm.dart';

/// A1: BOTH tool loops answer to the program's execution policy. Before
/// the shared ToolTurnRunner, the agent's internal loop had no policy
/// gate at all — an agent could call a tool the program policy forbade,
/// and nothing trapped.
void main() {
  ExecutionPolicy denySendAlert() => ExecutionPolicy(
    policyId: 'no_alerts',
    deniedCapabilities: [Capability.exact(PolicyAction.toolCall, 'send_alert')],
    defaultAllow: true,
  );

  Future<(VasterVMEngine, VasterRuntime)> boot(FakeVasterModel model, ExecutionPolicy policy) async {
    final vm = await VasterVMEngine.bootstrap(
      config: VMConfig(defaultModel: model, rootMountPath: '/mem'),
    );
    vm.registerTool(
      FunctionTool.define(
        name: 'send_alert',
        description: 'Send an alert',
        parametersSchema: const {
          'type': 'object',
          'properties': {
            'msg': {'type': 'string'},
          },
        },
        handler: (args) => {'status': 'sent'},
      ),
    );
    final runtime = VasterRuntime(
      vm: vm,
      policy: policy,
      budget: ExecutionBudget.unlimited(),
      scheduler: BasicVasterScheduler(taskQueue: PriorityTaskQueue()),
    );
    return (vm, runtime);
  }

  FakeVasterModel toolCallingModel() {
    var calls = 0;
    return FakeVasterModel(
      handler: (request) {
        calls++;
        if (calls == 1) {
          return ModelResponse(
            message: const ChatMessage(
              role: Role.model,
              parts: [
                TextPart('Alerting.'),
                FunctionCallPart(callId: 'c1', name: 'send_alert', arguments: {'msg': 'x'}),
              ],
            ),
            finishReason: FinishReason.toolCalls,
          );
        }
        return ModelResponse(message: ChatMessage.model('done'));
      },
    );
  }

  test('an AGENT tool call forbidden by the program policy traps — '
      'uncatchable, even inside a retry loop', () async {
    final (vm, runtime) = await boot(toolCallingModel(), denySendAlert());
    addTearDown(vm.shutdown);

    const program = VasterProgram(
      programName: 'agent_gate',
      instructions: [
        CreateAgentOp(
          descriptor: AgentDescriptor(agentId: 'a', name: 'A', role: 'r', systemInstruction: 's'),
        ), // 0
        // Even a handler must not catch the violation.
        PushErrorHandlerOp(targetPc: 4, errorVar: 'err'), // 1
        DispatchAgentTaskOp(agentId: 'a', taskPrompt: 'alert someone'), // 2
        PopErrorHandlerOp(), // 3
        HaltOp(), // 4
      ],
    );

    final state = await runtime.executeProgram(program);
    expect(
      state.status,
      RuntimeStatus.error,
      reason:
          'a policy violation inside an AGENT tool loop is a '
          'security trap, not a recoverable program error',
    );
    expect(state.errorDetails, contains('send_alert'));
  });

  test('the ISA tool loop traps identically — one gate, two loops', () async {
    final (vm, runtime) = await boot(toolCallingModel(), denySendAlert());
    addTearDown(vm.shutdown);

    const program = VasterProgram(
      programName: 'isa_gate',
      instructions: [
        PromptOp(promptText: 'alert someone', outputVar: 'out'),
        HaltOp(),
      ],
    );
    final state = await runtime.executeProgram(program);
    expect(state.status, RuntimeStatus.error);
    expect(state.errorDetails, contains('send_alert'));
  });

  test('a descriptor-declared agent policy composes ON TOP of the program '
      'policy (the dormant AgentDescriptor.policy field is law now)', () async {
    final (vm, runtime) = await boot(toolCallingModel(), ExecutionPolicy.unlimited);
    addTearDown(vm.shutdown);

    final program = VasterProgram(
      programName: 'descriptor_gate',
      instructions: [
        CreateAgentOp(
          descriptor: AgentDescriptor(
            agentId: 'restricted',
            name: 'R',
            role: 'r',
            systemInstruction: 's',
            policy: denySendAlert(),
          ),
        ), // 0
        const DispatchAgentTaskOp(agentId: 'restricted', taskPrompt: 'alert someone'), // 1
        const HaltOp(), // 2
      ],
    );
    final state = await runtime.executeProgram(program);
    expect(
      state.status,
      RuntimeStatus.error,
      reason:
          'the agent\'s own declared policy gates its tool calls '
          'even when the program policy allows everything',
    );
    expect(state.errorDetails, contains('send_alert'));
  });
}
