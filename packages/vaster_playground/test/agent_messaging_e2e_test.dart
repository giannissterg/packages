import 'package:test/test.dart';
import 'package:vaster_ast/vaster_ast.dart';
import 'package:vaster_compiler/vaster_compiler.dart';
import 'package:vaster_domain/vaster_domain.dart';
import 'package:vaster_model_fake/vaster_model_fake.dart';
import 'package:vaster_vm/vaster_vm.dart';

void main() {
  group('Inter-Agent Actor Messaging E2E Tests', () {
    late VasterVirtualMachine vm;
    late VasterRuntime runtime;

    setUp(() async {
      final fakeModel = FakeVasterModel();
      vm = await VasterVMEngine.bootstrap(config: VMConfig(defaultModel: fakeModel));
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

    test('Agent A sends message to Agent B, and Agent B receives it from inbox', () async {
      const aliceRole = AgentRole(
        roleId: 'alice',
        name: 'Alice Agent',
        title: 'Researcher',
        instruction: 'Sends findings to Bob.',
      );

      const bobRole = AgentRole(
        roleId: 'bob',
        name: 'Bob Agent',
        title: 'Reviewer',
        instruction: 'Receives findings from Alice.',
      );

      const compiler = BasicWorkflowCompiler();

      final pipeline = Pipeline(
        spec: const PipelineSpec(name: 'agent_messaging_pipeline'),
        roles: const [aliceRole, bobRole],
        children: [
          // Alice sends a message to Bob
          Agent(
            role: aliceRole,
            children: const [
              SendMessage(
                recipientAgentId: 'bob',
                payload: {'text': 'Alice completed initial research.'},
              ),
            ],
          ),

          // Bob receives the message from inbox
          Agent(
            role: bobRole,
            children: const [
              ReceiveMessage(),
            ],
          ),

          const Output(),
        ],
      );

      final program = compiler.compile(pipeline);
      final state = await runtime.executeProgram(program);

      expect(state.status, equals(RuntimeStatus.halted));
      expect(state.registers['__output__'], equals('Alice completed initial research.'));
    });
  });
}
