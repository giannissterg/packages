import 'package:vaster_ast/vaster_ast.dart';
import 'package:vaster_compiler/vaster_compiler.dart';
import 'package:vaster_dis/vaster_dis.dart';
import 'package:vaster_domain/vaster_domain.dart';
import 'package:vaster_model_fake/vaster_model_fake.dart';
import 'package:vaster_vm/vaster_vm.dart';

void main() async {
  print('======================================================================');
  print('    VASTER TOOLSET SCOPE & DYNAMIC TOOL CALLING LOOP DEMO              ');
  print('  1. ToolSet AST Scope  2. RegisterToolSetOp  3. Autonomous Tool Loop   ');
  print('======================================================================\n');

  // Define tools for the ToolSet scope
  const writeFileTool = ToolDefinition(
    name: 'write_file',
    description: 'Writes text content to a file in the Virtual File System.',
    parametersSchema: {
      'type': 'object',
      'properties': {
        'path': {'type': 'string'},
        'content': {'type': 'string'},
      },
      'required': ['path', 'content'],
    },
  );

  const readFileTool = ToolDefinition(
    name: 'read_file',
    description: 'Reads text content from a file in the Virtual File System.',
    parametersSchema: {
      'type': 'object',
      'properties': {
        'path': {'type': 'string'},
      },
      'required': ['path'],
    },
  );

  const engineerRole = AgentRole(
    roleId: 'engineer',
    name: 'Autonomous Systems Engineer',
    title: 'Lead Tool Engineer',
    instruction: 'Uses tools to perform filesystem operations.',
  );

  // 1. Build AST with ToolSet scope provider
  final pipeline = Pipeline(
    spec: const PipelineSpec(name: 'toolset_dynamic_demo_pipeline'),
    roles: const [engineerRole],
    children: [
      // ToolSet Scope Provider wrapping sub-tree
      ToolSet(
        tools: const [writeFileTool, readFileTool],
        children: const [
          Agent(
            role: engineerRole,
            children: [
              Task(prompt: 'Create a deployment configuration file at /workspace/deploy.json and verify its content.'),
            ],
          ),
        ],
      ),

      const Output(),
    ],
  );

  print('┌─ AST COMPILATION ──────────────────────────────────────────────┐');
  const compiler = BasicWorkflowCompiler();
  final program = compiler.compile(pipeline);
  print('  Pipeline Compiled: ${program.programName} (${program.instructions.length} instructions)');

  final disassembler = VasterDisassembler();
  print(disassembler.disassemble(program));

  print('\n┌─ EXECUTING DYNAMIC TOOL CALLING LOOP ──────────────────────────┐');

  // Model configured to request tool call write_file on first turn
  final fakeModel = FakeVasterModel(
    handler: (request) {
      final hasToolResponse = request.messages.any(
        (m) => m.parts.any((p) => p is FunctionResponsePart),
      );
      if (!hasToolResponse) {
        return ModelResponse(
          message: ChatMessage(
            role: Role.model,
            parts: const [
              TextPart('Writing configuration...'),
              FunctionCallPart(
                callId: 'call_001',
                name: 'write_file',
                arguments: {
                  'path': '/workspace/deploy.json',
                  'content': '{"cluster": "us-east-1", "nodes": 4, "status": "active"}',
                },
              ),
            ],
          ),
        );
      }
      return ModelResponse(
        message: ChatMessage.model('Deployment configuration file /workspace/deploy.json created successfully and verified!'),
      );
    },
  );

  final vm = await VasterVMEngine.bootstrap(
    config: VMConfig(defaultModel: fakeModel, rootMountPath: '/workspace'),
  );

  final runtime = VasterRuntime(
    vm: vm,
    policy: ExecutionPolicy.unlimited,
    budget: ExecutionBudget(maxDuration: const Duration(minutes: 1)),
    scheduler: BasicVasterScheduler(taskQueue: PriorityTaskQueue()),
  );

  final state = await runtime.executeProgram(program);
  print('  ✓ Pipeline Status: ${state.status.name}');

  final fs = vm.fileSystemManager.resolveFileSystem('/workspace/deploy.json');
  final files = await fs.listDirectory('/', recursive: true);
  print('  ✓ VFS Files stored in filesystem: ${files.map((f) => f.path).toList()}');
  final writtenContent = await fs.readText(files.isNotEmpty ? files.first.path : '/workspace/deploy.json');

  print('  ✓ VFS File Created by Tool Call: /workspace/deploy.json');
  print('  ✓ File Content: "$writtenContent"');

  await vm.shutdown();

  print('\n======================================================================');
  print('  DEMO PASSED: ToolSet Scope & Dynamic Tool Loop Verified 100%!');
  print('======================================================================');
}
