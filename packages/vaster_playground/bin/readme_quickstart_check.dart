// Guard against README rot: this file mirrors the root README's
// "30 Seconds" quickstart (with workspace imports). If the README's
// example API drifts, update both together.
import 'package:vaster_ast/vaster_ast.dart';
import 'package:vaster_compiler/vaster_compiler.dart';
import 'package:vaster_domain/vaster_domain.dart';
import 'package:vaster_model_fake/vaster_model_fake.dart';
import 'package:vaster_vm/vaster_vm.dart';

void main() async {
  // 1. Define LLM Agent Roles
  const architectRole = AgentRole(
    roleId: 'architect',
    name: 'Architect',
    title: 'Lead Software Architect',
    instruction: 'Expert in system design and clean code.',
  );

  // 2. Compose the declarative AST pipeline. `output:` binds a step's
  //    value; `${...}` interpolates it into later prompts at runtime.
  final pipeline = Pipeline(
    name: 'my_first_pipeline',
    roles: const [architectRole],
    children: const [
      Agent(
        role: architectRole,
        child: Task(
          prompt: 'Analyze the project architecture and design the notes entity.',
          output: 'design',
        ),
      ),
      Prompt('Summarize this design in one paragraph:\n\${design}'),
      Output(),
    ],
  );

  // 3. Compile AST to ISA Bytecode
  final compiler = BasicWorkflowCompiler();
  final program = compiler.compile(pipeline);

  // 4. Bootstrap Vaster VM Engine with Model Backend
  final vm = await VasterVMEngine.bootstrap(
    config: VMConfig(defaultModel: FakeVasterModel()),
  );

  // 5. Execute Pipeline in Vaster Runtime
  final runtime = VasterRuntime(
    vm: vm,
    policy: ExecutionPolicy.unlimited,
    budget: ExecutionBudget.unlimited(),
    scheduler: BasicVasterScheduler(taskQueue: PriorityTaskQueue()),
  );

  final state = await runtime.executeProgram(program);
  print('Pipeline execution status: ${state.status.name}');

  await vm.shutdown();
}
