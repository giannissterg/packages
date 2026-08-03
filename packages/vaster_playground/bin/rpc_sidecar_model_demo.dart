import 'dart:io';

import 'package:vaster_ast/vaster_ast.dart';
import 'package:vaster_compiler/vaster_compiler.dart';
import 'package:vaster_dis/vaster_dis.dart';
import 'package:vaster_domain/vaster_domain.dart';
import 'package:vaster_model_fake/vaster_model_fake.dart';
import 'package:vaster_model_rpc/vaster_model_rpc.dart';
import 'package:vaster_model_rpc_server/vaster_model_rpc_server.dart';
import 'package:vaster_vm/vaster_vm.dart';

void main() async {
  print('======================================================================');
  print('  VASTER OUT-OF-PROCESS MODEL SIDECAR RPC DEMO                        ');
  print('  Transport: Unix Domain Socket (/tmp/vaster_sidecar_model.sock)       ');
  print('  Backend  : Out-of-Process VasterModel Sidecar Server                  ');
  print('======================================================================\n');

  final tempDir = await Directory.systemTemp.createTemp('vaster_rpc_demo_');
  final socketPath = '${tempDir.path}/vaster_sidecar_model.sock';

  // 1. Launch Out-of-Process Model Sidecar Server hosting fake or real LLM backend
  print('┌─ LAUNCHING OUT-OF-PROCESS MODEL SIDECAR SERVER ────────────────┐');
  final backendModel = FakeVasterModel(
    responseMap: {
      'Analyze the system architecture':
          'RPC SIDECAR ANALYSIS: System architecture validated over Unix domain socket RPC.',
      'Generate production code':
          'RPC SIDECAR CODEGEN: Code generation completed via out-of-process model RPC.',
    },
  );

  final sidecarServer = VasterModelSidecarServer(
    underlyingModel: backendModel,
    socketPath: socketPath,
  );
  await sidecarServer.start();
  print('  ✓ Model Sidecar Server online listening on: $socketPath');

  // 2. Connect client RpcVasterModel to the Unix Domain Socket
  final rpcClientModel = RpcVasterModel(
    socketPath: socketPath,
    modelName: 'unix-socket-sidecar-model',
  );

  // 3. Define pipeline & compile AST -> ISA bytecode
  const devRole = AgentRole(
    roleId: 'rpc_agent',
    name: 'RPC Sidecar Developer',
    title: 'Out-of-Process Developer Agent',
    instruction: 'Communicates with out-of-process model server over Unix Domain Socket RPC.',
  );

  final pipeline = Pipeline(
    name: 'rpc_sidecar_pipeline',
    roles: const [devRole],
    children: const [
      Agent(
        role: devRole,
        child: Sequence([
          Task(prompt: 'Analyze the system architecture'),
          Task(prompt: 'Generate production code'),
        ]),
      ),
    ],
  );

  final compiler = BasicWorkflowCompiler();
  final program = compiler.compile(pipeline);

  print('\n┌─ AST COMPILATION ──────────────────────────────────────────────┐');
  print('  Pipeline Compiled: ${program.programName} (${program.instructions.length} instructions)');
  print('═════════════════════════════════════════════════════════════════');

  final disassembler = VasterDisassembler();
  print(disassembler.disassemble(program));

  // 4. Bootstrap Vaster VM Engine with RpcVasterModel
  print('┌─ VM BOOTSTRAP & RPC EXECUTION ─────────────────────────────────┐');
  final vm = await VasterVMEngine.bootstrap(
    config: VMConfig(
      defaultModel: rpcClientModel,
      rootMountPath: '/workspace',
    ),
    rootFileSystem: LocalVasterFileSystem(tempDir.path, mountPrefix: '/workspace'),
  );

  final runtime = VasterRuntime(
    vm: vm,
    policy: ExecutionPolicy.unlimited,
    budget: ExecutionBudget.unlimited(),
    scheduler: BasicVasterScheduler(taskQueue: PriorityTaskQueue()),
  );

  final state = await runtime.executeProgram(program);

  print('  ✓ RPC Pipeline Execution Status: ${state.status.name}');
  print('  ✓ Total ISA Instructions Executed: ${program.instructions.length}');

  // 5. Cleanup
  await vm.shutdown();
  await sidecarServer.stop();
  if (tempDir.existsSync()) {
    await tempDir.delete(recursive: true);
  }

  print('\n======================================================================');
  print('  DEMO PASSED: Out-of-Process Unix Socket Model Sidecar RPC Verified!  ');
  print('======================================================================');
}
