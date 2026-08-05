import 'dart:convert';

import 'package:test/test.dart';
import 'package:vaster_ast/vaster_ast.dart';
import 'package:vaster_compiler/vaster_compiler.dart';
import 'package:vaster_domain/vaster_domain.dart';
import 'package:vaster_model_fake/vaster_model_fake.dart';
import 'package:vaster_vm/vaster_vm.dart';

/// Compiler → ISA → runtime E2E coverage for the declarative Decide and
/// DecideLoop nodes — the model steering compiled control flow.
void main() {
  const compiler = BasicWorkflowCompiler();

  Pipeline pipeline(List<VasterNode> children, {Binding? result}) =>
      Pipeline(
        result: result,
        spec: const PipelineSpec(name: 'decide_e2e'),
        children: children,
      );

  Future<(VasterVirtualMachine, VasterRuntime)> boot(FakeVasterModel model) async {
    final vm = await VasterVMEngine.bootstrap(config: VMConfig(defaultModel: model));
    final runtime = VasterRuntime(
      vm: vm,
      policy: ExecutionPolicy.unlimited,
      budget: ExecutionBudget.unlimited(),
      scheduler: BasicVasterScheduler(taskQueue: PriorityTaskQueue()),
    );
    return (vm, runtime);
  }

  test('compiled Decide routes execution through the model-chosen path', () async {
    final model = FakeVasterModel(handler: (request) {
      final text = request.messages.last.text;
      if (text.contains('Choose exactly one')) {
        return ModelResponse(
          message: ChatMessage.model(jsonEncode(
              {'choice': 'escalate', 'rationale': 'severity is high'})),
        );
      }
      return ModelResponse(message: ChatMessage.model('handled: $text'));
    });
    final (vm, runtime) = await boot(model);

    final program = compiler.compile(pipeline(result: const Binding('handling'), const [
      Decide(
        prompt: Template.text('How should this incident be handled?'),
        output: Binding('handling'),
        paths: [
          DecisionPath(label: 'auto_fix', description: 'safe to fix automatically',
              children: [Prompt(Template.text('apply the automatic fix'))]),
          DecisionPath(label: 'escalate', description: 'needs a human',
              children: [Prompt(Template.text('page the on-call engineer'))]),
        ],
      ),
    ]));

    final state = await runtime.executeProgram(program);

    expect(state.status, RuntimeStatus.halted);
    expect(state.registers['handling'], equals('escalate'),
        reason: 'the chosen label is the Decide node\'s produced value');
    final prompts = model.recordedRequests.map((r) => r.messages.last.text);
    expect(prompts.any((p) => p.contains('page the on-call')), isTrue);
    expect(prompts.any((p) => p.contains('automatic fix')), isFalse,
        reason: 'the unchosen path must not execute');
    await vm.shutdown();
  });

  test('DecideLoop iterates until the model decides it is done', () async {
    var decisions = 0;
    final model = FakeVasterModel(handler: (request) {
      final text = request.messages.last.text;
      if (text.contains('Choose exactly one')) {
        decisions++;
        return ModelResponse(
          message: ChatMessage.model(
              jsonEncode({'choice': decisions < 3 ? 'continue' : 'done'})),
        );
      }
      return ModelResponse(message: ChatMessage.model('step output'));
    });
    final (vm, runtime) = await boot(model);

    final program = compiler.compile(pipeline(const [
      DecideLoop(
        prompt: Template.text('Is the task complete?'),
        continueDescription: 'more work is needed',
        body: [Prompt(Template.text('do the next work step'))],
        exits: [
          DecisionPath(label: 'done', description: 'task complete',
              children: [Prompt(Template.text('summarize the result'))]),
        ],
      ),
    ]));

    final state = await runtime.executeProgram(program);

    expect(state.status, RuntimeStatus.halted);
    final workSteps = model.recordedRequests
        .where((r) => r.messages.last.text.contains('next work step'));
    expect(workSteps, hasLength(3),
        reason: 'continue, continue, done → the body ran exactly 3 times');
    final summaries = model.recordedRequests
        .where((r) => r.messages.last.text.contains('summarize'));
    expect(summaries, hasLength(1));
    await vm.shutdown();
  });

  test('DecideLoop maxIterations forces termination on a runaway model', () async {
    final model = FakeVasterModel(handler: (request) {
      final text = request.messages.last.text;
      if (text.contains('Choose exactly one')) {
        return ModelResponse(
          message: ChatMessage.model(jsonEncode({'choice': 'continue'})),
        );
      }
      return ModelResponse(message: ChatMessage.model('step output'));
    });
    final (vm, runtime) = await boot(model);

    final program = compiler.compile(pipeline(const [
      Provider<DecisionPolicy>(
        value: DecisionPolicy(maxIterations: 3),
        children: [
          DecideLoop(
            prompt: Template.text('Keep going?'),
            continueDescription: 'more work is needed',
            body: [Prompt(Template.text('do the next work step'))],
            exits: [
              DecisionPath(label: 'done', description: 'task complete'),
            ],
          ),
        ],
      ),
    ]));

    final state = await runtime.executeProgram(program);

    expect(state.status, RuntimeStatus.halted,
        reason: 'the guard terminates a model that never stops');
    final workSteps = model.recordedRequests
        .where((r) => r.messages.last.text.contains('next work step'));
    expect(workSteps, hasLength(3));
    await vm.shutdown();
  });
}
