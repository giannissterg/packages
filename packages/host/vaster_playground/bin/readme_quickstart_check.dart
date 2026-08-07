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
    result: const Binding('summary'),
    name: 'my_first_pipeline',
    roles: const [architectRole],
    children: const [
      Agent(
        role: architectRole,
        child: Task(
          prompt: Template.text('Analyze the project architecture and design the notes entity.'),
          output: Binding('design'),
        ),
      ),
      Prompt(
        Template(['Summarize this design in one paragraph:\n', Binding('design')]),
        output: Binding('summary'),
      ),
    ],
  );

  // 3. Compile the AST to a serializable ISA program
  const compiler = BasicWorkflowCompiler();
  final program = compiler.compile(pipeline);

  // 4. Bootstrap the VM with a model backend
  final vm = await VasterVMEngine.bootstrap(config: VMConfig(defaultModel: FakeVasterModel()));

  // 5. Execute and read the declared result
  final runtime = VasterRuntime(
    vm: vm,
    policy: ExecutionPolicy.unlimited,
    budget: ExecutionBudget.unlimited(),
    scheduler: BasicVasterScheduler(taskQueue: PriorityTaskQueue()),
  );

  final state = await runtime.executeProgram(program);
  print('status : ${state.status.name}');
  print('summary: ${state.registers[program.resultBinding]}');

  await vm.shutdown();
}
