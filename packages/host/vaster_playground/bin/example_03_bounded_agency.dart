import 'dart:convert';

import 'package:vaster_ast/vaster_ast.dart';
import 'package:vaster_compiler/vaster_compiler.dart';
import 'package:vaster_model_fake/vaster_model_fake.dart';
import 'package:vaster_vm/vaster_vm.dart';

/// Example 03 — bounded agency with `Decide`.
///
/// The model steers control flow, but only among destinations declared in
/// the program: a `Decide` node compiles to a `DecideOp` whose full
/// decision surface is statically known — `vaster audit` can enumerate
/// every path the model could ever take, and the unchosen branch provably
/// never executes.
///
///     dart run vaster_playground:example_03_bounded_agency
void main() async {
  const pipeline = Pipeline(
    name: 'incident_router',
    inputs: {Binding('incident'): 'Checkout latency p99 jumped from 300ms to 9s.'},
    result: Binding('route'),
    children: [
      Decide(
        prompt: Template.text(
          'How should this incident be handled?\n'
          '\${incident}',
        ),
        output: Binding('route'),
        paths: [
          DecisionPath(
            label: 'auto_fix',
            description: 'safe to remediate automatically',
            children: [Prompt(Template.text('Apply the standard remediation runbook.'))],
          ),
          DecisionPath(
            label: 'escalate',
            description: 'needs a human on-call engineer',
            children: [Prompt(Template.text('Draft the page for the on-call engineer.'))],
          ),
        ],
      ),
    ],
  );

  const compiler = BasicWorkflowCompiler();
  final program = compiler.compile(pipeline);

  // The fake model answers the decision prompt with the structured choice
  // the runtime asks for, and echoes any other prompt. A real backend gets
  // the identical contract: choose one label, give a rationale.
  final model = FakeVasterModel(
    handler: (request) {
      final prompt = request.messages.last.text;
      if (prompt.contains('Choose exactly one')) {
        return ModelResponse(
          message: ChatMessage.model(
            jsonEncode({'choice': 'escalate', 'rationale': 'a 30x latency regression needs a human now'}),
          ),
        );
      }
      return ModelResponse(message: ChatMessage.model('done: $prompt'));
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

  print('status : ${state.status.name}');
  print('route  : ${state.registers[program.resultBinding]}');

  // Proof that agency stayed bounded: the chosen path's prompt ran, the
  // other never reached the model.
  final prompts = model.recordedRequests.map((r) => r.messages.last.text);
  print('paged on-call     : ${prompts.any((p) => p.contains('on-call'))}');
  print('ran auto-fix path : ${prompts.any((p) => p.contains('runbook'))}');

  await vm.shutdown();
}
