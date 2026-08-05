import 'package:test/test.dart';
import 'package:vaster_ast/vaster_ast.dart';
import 'package:vaster_compiler/vaster_compiler.dart';
import 'package:vaster_model_fake/vaster_model_fake.dart';
import 'package:vaster_vm/vaster_vm.dart';

/// Compiler → ISA → runtime E2E coverage for the ApprovalGate composable node.
///
/// ISA-level HITL behavior is tested in
/// `vaster_runtime/test/human_interaction_runtime_test.dart` with
/// hand-assembled programs.
void main() {
  group('ApprovalGate — compiled pipeline execution', () {
    late VasterVirtualMachine vm;

    setUp(() async {
      vm = await VasterVMEngine.bootstrap(
          config: VMConfig(defaultModel: FakeVasterModel()));
    });

    tearDown(() async {
      await vm.shutdown();
    });

    test('AST ApprovalGate node compiles and executes end-to-end with approve and reject branches', () async {
      final compiler = BasicWorkflowCompiler();
      final pipeline = Pipeline(
        name: 'ast_approval_gate_pipeline',
        children: const [
          ApprovalGate(
            requestId: 'ast_gate_001',
            prompt: Template.text('Approve AST Pipeline execution?'),
            onApprove: [
              WriteFile(path: Template.text('/mem/ast_res.txt'), content: Template.text('AST_APPROVED')),
            ],
            onReject: [
              WriteFile(path: Template.text('/mem/ast_res.txt'), content: Template.text('AST_REJECTED')),
            ],
          ),
        ],
      );

      final program = compiler.compile(pipeline);

      // Test 1: Approval flow
      final runtimeApprove = VasterRuntime(
        vm: vm,
        policy: ExecutionPolicy.unlimited,
        budget: ExecutionBudget.unlimited(),
        scheduler: BasicVasterScheduler(taskQueue: PriorityTaskQueue()),
      );

      var stateApprove = await runtimeApprove.executeProgram(program);
      expect(stateApprove.status, equals(RuntimeStatus.pausedForHuman));
      expect(runtimeApprove.pendingHumanRequest?.requestId, equals('ast_gate_001'));

      stateApprove = await runtimeApprove.resumeWithHumanResponse(
        HumanInteractionResponse.approve(requestId: 'ast_gate_001'),
      );
      expect(stateApprove.status, equals(RuntimeStatus.halted));

      final approveContent = await vm.fileSystemManager
          .resolveFileSystem('/mem/ast_res.txt')
          .readText('/mem/ast_res.txt');
      expect(approveContent, equals('AST_APPROVED'));

      // Test 2: Rejection flow
      final runtimeReject = VasterRuntime(
        vm: vm,
        policy: ExecutionPolicy.unlimited,
        budget: ExecutionBudget.unlimited(),
        scheduler: BasicVasterScheduler(taskQueue: PriorityTaskQueue()),
      );

      var stateReject = await runtimeReject.executeProgram(program);
      expect(stateReject.status, equals(RuntimeStatus.pausedForHuman));

      stateReject = await runtimeReject.resumeWithHumanResponse(
        HumanInteractionResponse.reject(requestId: 'ast_gate_001', reason: 'Rejected by security'),
      );
      expect(stateReject.status, equals(RuntimeStatus.halted));

      final rejectContent = await vm.fileSystemManager
          .resolveFileSystem('/mem/ast_res.txt')
          .readText('/mem/ast_res.txt');
      expect(rejectContent, equals('AST_REJECTED'));
    });
  });
}
