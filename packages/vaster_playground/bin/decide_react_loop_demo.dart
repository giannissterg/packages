import 'dart:convert';
import 'dart:io';

import 'package:vaster_ast/vaster_ast.dart';
import 'package:vaster_compiler/vaster_compiler.dart';
import 'package:vaster_model_fake/vaster_model_fake.dart';
import 'package:vaster_vm/vaster_vm.dart';

/// A ReAct-style agent loop as a pure declarative tree: [DecideLoop] runs its
/// body, then the model decides whether another pass is needed. No condition
/// variables, no registers — iteration control *is* the decision, and
/// [DecisionPolicy] flows in Flutter-Theme-style via `Provider`.
Future<void> main() async {
  var passes = 0;
  final model = FakeVasterModel(handler: (request) {
    final text = request.messages.last.text;
    if (text.contains('Choose exactly one')) {
      passes++;
      final done = passes >= 3;
      return ModelResponse(
        message: ChatMessage.model(jsonEncode({
          'choice': done ? 'done' : 'continue',
          'rationale': done
              ? 'All findings are addressed.'
              : 'Open findings remain after pass $passes.',
        })),
      );
    }
    return ModelResponse(message: ChatMessage.model('pass output'));
  });

  final pipeline = Pipeline(
    name: 'iterative_refactor',
    children: const [
      Provider<DecisionPolicy>(
        value: DecisionPolicy(maxIterations: 5),
        children: [
          DecideLoop(
            prompt: 'Is the refactor complete and are all findings addressed?',
            continueDescription: 'open findings remain — run another pass',
            body: [Prompt('Run the next refactoring pass and list findings.')],
            exits: [
              DecisionPath(
                label: 'done',
                description: 'the refactor is complete',
                children: [Prompt('Summarize everything that changed.')],
              ),
            ],
          ),
        ],
      ),
    ],
  );

  final program = const BasicWorkflowCompiler().compile(pipeline);
  final vm = await VasterVMEngine.bootstrap(config: VMConfig(defaultModel: model));
  vm.eventBus.on<DecisionMadeEvent>().listen((event) => stdout.writeln(
      '[decision] ${event.chosenLabel} — ${event.rationale ?? '(no rationale)'}'));
  final runtime = VasterRuntime(
    vm: vm,
    policy: ExecutionPolicy.unlimited,
    budget: ExecutionBudget.unlimited(),
    scheduler: BasicVasterScheduler(taskQueue: PriorityTaskQueue()),
  );

  final state = await runtime.executeProgram(program);
  await Future<void>.delayed(Duration.zero);

  stdout.writeln('\nstatus : ${state.status.name}');
  stdout.writeln('passes : $passes model decisions, loop exited via '
      '"${state.registers.values.contains('done') ? 'done' : 'guard'}"');
  await vm.shutdown();
}
