// ignore_for_file: avoid_print
import 'package:vaster_model_fake/vaster_model_fake.dart';
import 'package:vaster_vm/vaster_vm.dart';

/// Live disassembly-style execution trace: attach an [ExecutionTracer] and
/// watch the VM run instruction by instruction.
Future<void> main() async {
  final vm = await VasterVMEngine.bootstrap(
    config: VMConfig(defaultModel: FakeVasterModel(defaultResponseText: 'Done.')),
  );
  final runtime = VasterRuntime(
    vm: vm,
    policy: ExecutionPolicy.unlimited,
    budget: ExecutionBudget.unlimited(),
    scheduler: BasicVasterScheduler(taskQueue: PriorityTaskQueue()),
  );

  final tracer = ExecutionTracer(runtime, sink: print)..attach();

  const program = VasterProgram(programName: 'trace_showcase', instructions: [
    SetRegisterOp(registerName: 'goal', value: 'ship the feature'),
    WriteFileOp(vfsPath: '/mem/plan.md', content: '# Plan\n1. build\n2. test'),
    ReadFileOp(vfsPath: '/mem/plan.md', outputVar: 'plan'),
    PromptOp(promptText: 'Summarize the plan', outputVar: 'summary'),
    JumpIfOp(conditionVar: 'summary', targetPc: 6),
    SetRegisterOp(registerName: 'fallback', value: 'no summary'),
    ConcatRegisterOp(targetVar: '__output__', sourceVars: ['summary']),
    HaltOp(),
  ]);

  final state = await runtime.executeProgram(program);
  tracer.detach();

  print('\nfinal status: ${state.status.name}');
  await vm.shutdown();
}
