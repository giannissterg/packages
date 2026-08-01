import 'dart:convert';

import 'package:vaster_ast/vaster_ast.dart';
import 'package:vaster_compiler/vaster_compiler.dart';
import 'package:vaster_continuation/vaster_continuation.dart';
import 'package:vaster_domain/vaster_domain.dart';
import 'package:vaster_model_fake/vaster_model_fake.dart';
import 'package:vaster_runtime/vaster_runtime.dart';
import 'package:vaster_vm/vaster_vm.dart';

void main() async {
  print('================================================================');
  print('       Vaster Continuation & Snapshot Manager Demo              ');
  print('================================================================\n');

  // 1. Bootstrap VM & Compiler
  final vm = await VasterVMEngine.bootstrap(
    config: VMConfig(defaultModel: FakeVasterModel()),
  );
  const compiler = BasicWorkflowCompiler();
  final continuationManager = ContinuationManager();

  // 2. Build AST with Human Approval Gate
  final pipeline = PipelineNode(
    spec: const PipelineSpec(name: 'production_deployment_pipeline'),
    bodyNodes: [
      WriteDocumentNode(path: '/mem/build.log', content: 'Build succeeded.'),
      HumanApprovalComponent(
        requestId: 'deploy_to_prod',
        prompt: 'Deploy release v1.2.0 to production?',
        onApprove: const [
          WriteDocumentNode(path: '/mem/release.log', content: 'v1.2.0 Live in Prod.'),
        ],
      ),
    ],
  );

  final program = compiler.compile(pipeline);

  // 3. Start execution
  print('▶ 1. Starting execution on Server Instance #1...');
  final runtime1 = VasterRuntime(vm: vm);
  final state1 = await runtime1.executeProgram(program);
  print('   Status: ${state1.status.name} (PC: ${state1.pc})\n');

  // 4. Capture continuation snapshot and serialize to JSON
  print('💾 2. Capturing VasterContinuation snapshot...');
  final snapshot = continuationManager.capture(runtime1, program.programName);
  final jsonString = const JsonEncoder.withIndent('  ').convert(snapshot.toJson());
  print('   Snapshot JSON Payload:');
  print('$jsonString\n');

  // 5. Simulate Server Restart / Restore on Server Instance #2
  print('🔄 3. Restoring snapshot on Server Instance #2 & approving deployment...');
  final restoredSnapshot = VasterContinuation.fromJson(jsonDecode(jsonString));
  final runtime2 = VasterRuntime(vm: vm);

  final finalState = await continuationManager.restoreAndResume(
    runtime2,
    restoredSnapshot,
    program,
    humanResponse: HumanInteractionResponse.approve(requestId: 'deploy_to_prod'),
  );

  print('   Status: ${finalState.status.name}');
  final log = await vm.fileSystemManager.resolveFileSystem('/mem/release.log').readText('/mem/release.log');
  print('   Release Log: "$log"');
  print('✅ Pipeline completed successfully!');
}
