import 'package:vaster_ast/vaster_ast.dart';
import 'package:vaster_compiler/vaster_compiler.dart';
import 'package:vaster_model_fake/vaster_model_fake.dart';
import 'package:vaster_vm/vaster_vm.dart';

/// Example 01 — your first pipeline.
///
/// The complete Vaster loop in one file: declare a two-step pipeline where
/// the second step consumes the first step's output through a typed
/// `Binding`, compile it to a serializable ISA program, execute it on a
/// scripted fake model (zero cost, zero network), and read the pipeline's
/// declared result out of the halted machine.
///
///     dart run vaster_playground:example_01_hello_pipeline
void main() async {
  // A Pipeline is a declarative tree. Value flow is explicit: `output:`
  // binds a step's produced value, `${name}` (or a Binding in a Template
  // part list) consumes it later. The compiler rejects a read that no
  // step is guaranteed to have written.
  const pipeline = Pipeline(
    name: 'hello_vaster',
    inputs: {Binding('topic'): 'durable LLM workflows'},
    result: Binding('summary'),
    children: [
      Prompt(Template.text('Write three short bullet points about \${topic}.'), output: Binding('bullets')),
      Prompt(
        Template(['Compress these bullets into one sentence:\n', Binding('bullets')]),
        output: Binding('summary'),
      ),
    ],
  );

  // Compile to a flat, JSON/binary-serializable instruction program. This
  // artifact — not the Dart tree — is what the runtime executes, what
  // `vaster check` proves things about, and what a checkpoint references.
  const compiler = BasicWorkflowCompiler();
  final program = compiler.compile(pipeline);
  print(
    'compiled ${program.instructions.length} instructions '
    '(result binding: ${program.resultBinding})',
  );

  // A scripted fake model: deterministic, free, offline. Swap in a real
  // backend (ClaudeCliVasterModel, GoogleAiVasterModel, …) without
  // touching the pipeline or the compiled program.
  final model = FakeVasterModel(
    handler: (request) {
      final prompt = request.messages.last.text;
      if (prompt.contains('bullet points')) {
        return ModelResponse(
          message: ChatMessage.model(
            '- pipelines compile to bytecode\n'
            '- execution can suspend to a checkpoint\n'
            '- a fresh process can resume it',
          ),
        );
      }
      return ModelResponse(
        message: ChatMessage.model(
          'Vaster compiles pipelines to bytecode whose execution can '
          'suspend to a checkpoint and resume in a fresh process.',
        ),
      );
    },
  );

  final vm = await VasterVMEngine.bootstrap(config: VMConfig(defaultModel: model));
  final runtime = VasterRuntime(
    vm: vm,
    policy: ExecutionPolicy.unlimited,
    budget: ExecutionBudget.unlimited(),
    scheduler: BasicVasterScheduler(taskQueue: PriorityTaskQueue()),
  );

  final state = await runtime.executeProgram(program);

  // The pipeline declared `result: Binding('summary')`; after halt that
  // value sits in the register named by the program header.
  print('status : ${state.status.name}');
  print('summary: ${state.registers[program.resultBinding]}');

  await vm.shutdown();
}
