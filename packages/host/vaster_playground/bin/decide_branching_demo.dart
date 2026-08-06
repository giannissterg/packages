import 'dart:convert';
import 'dart:io';

import 'package:vaster_ast/vaster_ast.dart';
import 'package:vaster_compiler/vaster_compiler.dart';
import 'package:vaster_dis/vaster_dis.dart';
import 'package:vaster_model_fake/vaster_model_fake.dart';
import 'package:vaster_vm/vaster_vm.dart';

/// Model-steered branching: a declarative [Decide] node compiles to a
/// [DecideOp] whose destinations are statically known — the model holds the
/// wheel, but only within compiler-emitted paths.
Future<void> main() async {
  final model = FakeVasterModel(handler: (request) {
    final text = request.messages.last.text;
    if (text.contains('Choose exactly one')) {
      return ModelResponse(
        message: ChatMessage.model(jsonEncode({
          'choice': 'escalate',
          'rationale': 'Payment data may be affected — a human must review.',
        })),
      );
    }
    return ModelResponse(message: ChatMessage.model('done: $text'));
  });

  final pipeline = Pipeline(
    result: const Binding('incident_path'),
    name: 'incident_triage',
    children: const [
      Decide(
        output: Binding('incident_path'),
        prompt: Template.text('An alert fired for elevated error rates on the payments '
            'service. How should this incident be handled?'),
        paths: [
          DecisionPath(
            label: 'auto_fix',
            description: 'transient and safe to remediate automatically',
            children: [Prompt(Template.text('Roll back the last deploy and verify.'))],
          ),
          DecisionPath(
            label: 'escalate',
            description: 'potentially customer-impacting, page a human',
            children: [Prompt(Template.text('Page the on-call engineer with a summary.'))],
          ),
        ],
      ),
    ],
  );

  const compiler = BasicWorkflowCompiler();
  final program = compiler.compile(pipeline);

  stdout.writeln('── Disassembly — the decision surface is statically visible:');
  stdout.writeln(const VasterDisassembler().disassemble(program));

  final vm = await VasterVMEngine.bootstrap(config: VMConfig(defaultModel: model));
  vm.eventBus.on<DecisionMadeEvent>().listen((event) =>
      stdout.writeln('[decision] ${jsonEncode(event.toJson())}'));
  final runtime = VasterRuntime(
    vm: vm,
    policy: ExecutionPolicy.unlimited,
    budget: ExecutionBudget.unlimited(),
    scheduler: BasicVasterScheduler(taskQueue: PriorityTaskQueue()),
  );

  final state = await runtime.executeProgram(program);
  await Future<void>.delayed(Duration.zero);

  stdout.writeln('\nstatus : ${state.status.name}');
  stdout.writeln('chosen : ${state.registers['incident_path']}');
  await vm.shutdown();
}
