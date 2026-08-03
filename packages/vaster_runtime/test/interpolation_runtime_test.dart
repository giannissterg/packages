import 'dart:io';

import 'package:test/test.dart';
import 'package:vaster_model_fake/vaster_model_fake.dart';
import 'package:vaster_vm/vaster_vm.dart';

/// ISA-level `${name}` interpolation semantics, hand-built programs only.
void main() {
  group('Runtime register interpolation', () {
    late FakeVasterModel model;
    late VasterVMEngine vm;
    late VasterRuntime runtime;

    setUp(() async {
      model = FakeVasterModel(defaultResponseText: 'model says hi');
      vm = await VasterVMEngine.bootstrap(
          config: VMConfig(defaultModel: model, rootMountPath: '/mem'));
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

    test('PromptOp text interpolates a prior output register', () async {
      const program = VasterProgram(programName: 'interp_prompt', instructions: [
        SetRegisterOp(registerName: 'topic', value: 'billing errors'),
        PromptOp(promptText: r'Summarize findings about ${topic}.'),
        HaltOp(),
      ]);
      final state = await runtime.executeProgram(program);
      expect(state.status, RuntimeStatus.halted);
      expect(model.recordedRequests.single.messages.last.text,
          equals('Summarize findings about billing errors.'));
    });

    test('WriteFileOp interpolates content and path; ReadFileOp reads it back',
        () async {
      const program = VasterProgram(programName: 'interp_vfs', instructions: [
        SetRegisterOp(registerName: 'doc', value: 'the plan'),
        SetRegisterOp(registerName: 'stem', value: 'plan'),
        WriteFileOp(vfsPath: r'/mem/${stem}.md', content: r'# Plan\n${doc}'),
        ReadFileOp(vfsPath: r'/mem/${stem}.md', outputVar: 'readback'),
        HaltOp(),
      ]);
      final state = await runtime.executeProgram(program);
      expect(state.status, RuntimeStatus.halted);
      expect('${state.registers['readback']}', contains('the plan'));
      expect('${state.registers['readback']}', isNot(contains(r'${doc}')));
    });

    test('policy evaluates the resolved path, not the template', () async {
      final restrictedVm = await VasterVMEngine.bootstrap(
        config: VMConfig(defaultModel: model, rootMountPath: '/mem'),
        policyEngine: BasicPolicyEngine(),
      );
      final restricted = VasterRuntime(
        vm: restrictedVm,
        policy: ExecutionPolicy.readOnly,
        budget: ExecutionBudget.unlimited(),
        scheduler: BasicVasterScheduler(taskQueue: PriorityTaskQueue()),
      );
      const program = VasterProgram(programName: 'interp_policy', instructions: [
        SetRegisterOp(registerName: 'p', value: '/mem/secret.txt'),
        WriteFileOp(vfsPath: r'${p}', content: 'x'),
        HaltOp(),
      ]);
      final state = await restricted.executeProgram(program);
      expect(state.status, RuntimeStatus.error);
      expect(state.errorDetails, contains('Policy violation'));
      await restrictedVm.shutdown();
    });

    test('unresolved reference stays verbatim and emits RuntimeWarningEvent',
        () async {
      final warnings = <RuntimeWarningEvent>[];
      vm.eventBus.on<RuntimeWarningEvent>().listen(warnings.add);

      const program = VasterProgram(programName: 'interp_warn', instructions: [
        PromptOp(promptText: r'about ${never_written}'),
        HaltOp(),
      ]);
      await runtime.executeProgram(program);
      await Future<void>.delayed(Duration.zero);

      expect(model.recordedRequests.single.messages.last.text,
          equals(r'about ${never_written}'));
      expect(warnings.single.code, equals('unresolved_interpolation'));
      expect(warnings.single.message, contains('never_written'));
    });

    test('MountFsOp with diskPath mounts a real local filesystem', () async {
      final tempDir =
          await Directory.systemTemp.createTemp('vaster_interp_mount_');
      final program = VasterProgram(programName: 'disk_mount', instructions: [
        MountFsOp(mountPrefix: '/disk', diskPath: tempDir.path),
        const WriteFileOp(vfsPath: '/disk/artifact.md', content: 'persisted'),
        const HaltOp(),
      ]);
      final state = await runtime.executeProgram(program);
      expect(state.status, RuntimeStatus.halted);
      final onDisk = File('${tempDir.path}/artifact.md');
      expect(onDisk.existsSync(), isTrue,
          reason: 'a declared diskPath must produce a real file on disk');
      expect(onDisk.readAsStringSync(), equals('persisted'));
      await tempDir.delete(recursive: true);
    });

    test('RegisterSandboxOp timeoutMs bounds sandbox execution', () async {
      vm.registerSandbox(IsolateCodeSandbox(
        descriptor: const SandboxDescriptor(
          sandboxId: 'slow_box',
          type: 'isolate',
          description: 'slow sandbox',
        ),
        defaultPolicy:
            const SandboxSecurityPolicy(maxTimeout: Duration(milliseconds: 50)),
        evaluator: (code, inputs) async {
          await Future<void>.delayed(const Duration(seconds: 2));
          return 'too late';
        },
      ));
      const program = VasterProgram(programName: 'sandbox_timeout', instructions: [
        ExecSandboxOp(sandboxId: 'slow_box', code: '1+1', outputVar: 'r'),
        HaltOp(),
      ]);
      final state = await runtime.executeProgram(program);
      expect('${state.registers['r']}', isNot(contains('too late')));
    });
  });
}
