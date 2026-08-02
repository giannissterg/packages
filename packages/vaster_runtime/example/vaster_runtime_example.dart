import 'package:vaster_budget/vaster_budget.dart';
import 'package:vaster_instruction/vaster_instruction.dart';
import 'package:vaster_model_fake/vaster_model_fake.dart';
import 'package:vaster_policy/vaster_policy.dart';
import 'package:vaster_runtime/vaster_runtime.dart';
import 'package:vaster_scheduler/vaster_scheduler.dart';
import 'package:vaster_vm/vaster_vm.dart';

void main() async {
  print('================================================================');
  print('          Vaster Low-Level ISA Runtime Engine Demo              ');
  print('================================================================');

  final fakeModel = FakeVasterModel(
    defaultResponseText: 'AI Analysis: Code is production-ready.',
  );

  final vm = await VasterVMEngine.bootstrap(
    config: VMConfig(
      defaultModel: fakeModel,
      rootMountPath: '/mem',
    ),
  );

  final runtime = VasterRuntime(
    vm: vm,
    policy: ExecutionPolicy.unlimited,
    budget: ExecutionBudget.unlimited(),
    scheduler: BasicVasterScheduler(taskQueue: PriorityTaskQueue()),
  );

  const program = VasterProgram(
    programName: 'multi_step_isa_pipeline',
    instructions: [
      MountFsOp(mountPrefix: '/mem'),
      WriteFileOp(vfsPath: '/mem/auth.txt', content: 'Auth Service Spec'),
      ReadFileOp(vfsPath: '/mem/auth.txt', outputVar: 'spec_content'),
      PromptOp(promptText: 'Implement Auth Service', outputVar: 'prompt_res'),
      HaltOp(),
    ],
  );

  print('Executing ISA Program: ${program.programName}...\n');
  final state = await runtime.executeProgram(program);

  print('=== Runtime Execution Finished ===');
  print('Status: ${state.status.name}');
  print('Program Counter (PC): ${state.pc}');
  print('Registers:');
  state.registers.forEach((key, value) {
    print('  $key = $value');
  });

  await vm.shutdown();
  print('\nDone!');
}
