import 'package:test/test.dart';
import 'package:vaster_ast/vaster_ast.dart';
import 'package:vaster_compiler/vaster_compiler.dart';
import 'package:vaster_continuation/vaster_continuation.dart';
import 'package:vaster_domain/vaster_domain.dart';
import 'package:vaster_model_fake/vaster_model_fake.dart';
import 'package:vaster_policy/vaster_policy.dart';
import 'package:vaster_runtime/vaster_runtime.dart';
import 'package:vaster_vm/vaster_vm.dart';

void main() {
  group('ContinuationManager & VasterContinuation Package', () {
    late VasterVirtualMachine vm;
    late ContinuationManager continuationManager;

    setUp(() async {
      vm = await VasterVMEngine.bootstrap(
        config: VMConfig(defaultModel: FakeVasterModel()),
      );
      continuationManager = ContinuationManager();
    });

    test('captures and restores execution continuation snapshot using ContinuationManager', () async {
      const compiler = BasicWorkflowCompiler();

      final pipeline = PipelineNode(
        spec: const PipelineSpec(name: 'continuation_pkg_pipeline'),
        bodyNodes: [
          WriteDocumentNode(path: '/mem/step1.txt', content: 'step_1_done'),
          HumanApprovalComponent(
            requestId: 'approval_pkg_001',
            prompt: 'Approve continuation package test?',
            onApprove: const [
              WriteDocumentNode(path: '/mem/step2.txt', content: 'step_2_done'),
            ],
          ),
        ],
      );

      final program = compiler.compile(pipeline);

      // 1. Execute program until HITL yield
      final runtime1 = VasterRuntime(vm: vm, policy: ExecutionPolicy.unlimited);
      final state1 = await runtime1.executeProgram(program);
      expect(state1.status, equals(RuntimeStatus.pausedForHuman));

      // 2. Capture continuation snapshot using dedicated ContinuationManager
      final snapshot = continuationManager.capture(runtime1, program.programName);
      final jsonMap = snapshot.toJson();

      // 3. Reconstruct snapshot from JSON
      final restoredSnapshot = VasterContinuation.fromJson(jsonMap);
      expect(restoredSnapshot.programName, equals('continuation_pkg_pipeline'));

      // 4. Restore execution on a fresh runtime instance
      final runtime2 = VasterRuntime(vm: vm, policy: ExecutionPolicy.unlimited);
      final state2 = await continuationManager.restoreAndResume(
        runtime2,
        restoredSnapshot,
        program,
        humanResponse: HumanInteractionResponse.approve(requestId: 'approval_pkg_001'),
      );

      expect(state2.status, equals(RuntimeStatus.halted));
      final step2Content = await vm.fileSystemManager
          .resolveFileSystem('/mem/step2.txt')
          .readText('/mem/step2.txt');
      expect(step2Content, equals('step_2_done'));
    });
  });
}
