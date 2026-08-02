import 'package:test/test.dart';
import 'package:vaster_budget/vaster_budget.dart';
import 'package:vaster_instruction/vaster_instruction.dart';
import 'package:vaster_model_fake/vaster_model_fake.dart';
import 'package:vaster_policy/vaster_policy.dart';
import 'package:vaster_policy_engine/vaster_policy_engine.dart';
import 'package:vaster_runtime/vaster_runtime.dart';
import 'package:vaster_scheduler/vaster_scheduler.dart';
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
  });
}
