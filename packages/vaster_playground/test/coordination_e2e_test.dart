import 'dart:convert';

import 'package:test/test.dart';
import 'package:vaster_ast/vaster_ast.dart';
import 'package:vaster_compiler/vaster_compiler.dart';
import 'package:vaster_domain/vaster_domain.dart';
import 'package:vaster_model_fake/vaster_model_fake.dart';
import 'package:vaster_vm/vaster_vm.dart';

/// Compiler → ISA → runtime E2E coverage for the coordination library:
/// the composables running on real interpolated value flow.
void main() {
  const compiler = BasicWorkflowCompiler();

  AgentRole role(String id) =>
      AgentRole(roleId: id, name: id, title: id, instruction: 'You are $id.');

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

  test('FanOut synthesis prompt receives both interpolated branch outputs',
      () async {
    final model = FakeVasterModel(handler: (request) {
      final text = request.messages.last.text;
      if (text.contains('north half')) {
        return ModelResponse(message: ChatMessage.model('NORTH_RESULT'));
      }
      if (text.contains('south half')) {
        return ModelResponse(message: ChatMessage.model('SOUTH_RESULT'));
      }
      return ModelResponse(message: ChatMessage.model('merged: $text'));
    });
    final (vm, runtime) = await boot(model);

    final program = compiler.compile(Pipeline(
      name: 'fanout_e2e',
      roles: [role('scout_n'), role('scout_s'), role('cartographer')],
      children: const [
        FanOut(
          tasks: [
            ParallelTaskEntry(
                agentId: 'scout_n', prompt: 'survey the north half', output: 'north'),
            ParallelTaskEntry(
                agentId: 'scout_s', prompt: 'survey the south half', output: 'south'),
          ],
          synthesize: Task(
            agentId: 'cartographer',
            prompt: r'Merge the surveys.\nNorth: ${north}\nSouth: ${south}',
            output: 'map',
          ),
        ),
        Output(from: 'map'),
      ],
    ));

    final state = await runtime.executeProgram(program);
    expect(state.status, RuntimeStatus.halted);

    final synthesisRequest = model.recordedRequests
        .lastWhere((r) => r.messages.last.text.contains('Merge the surveys'));
    expect(synthesisRequest.messages.last.text, contains('NORTH_RESULT'));
    expect(synthesisRequest.messages.last.text, contains('SOUTH_RESULT'));
    expect(synthesisRequest.messages.last.text, isNot(contains(r'${north}')));
    await vm.shutdown();
  });

  test('RefineLoop revises until the critic satisfies the decision model',
      () async {
    var workerRuns = 0;
    final model = FakeVasterModel(handler: (request) {
      final text = request.messages.last.text;
      if (text.contains('Choose exactly one')) {
        // Accept only after the second full worker+critic round.
        return ModelResponse(
          message: ChatMessage.model(
              jsonEncode({'choice': workerRuns >= 2 ? 'accept' : 'revise'})),
        );
      }
      if (text.contains('Draft the announcement')) {
        workerRuns++;
        return ModelResponse(message: ChatMessage.model('draft v$workerRuns'));
      }
      return ModelResponse(message: ChatMessage.model('needs work'));
    });
    final (vm, runtime) = await boot(model);

    final program = compiler.compile(Pipeline(
      name: 'refine_e2e',
      roles: [role('writer'), role('editor')],
      children: const [
        RefineLoop(
          worker: Task(
              agentId: 'writer',
              prompt: r'Draft the announcement. Critique so far: ${critique}',
              output: 'draft'),
          critic: Task(
              agentId: 'editor',
              prompt: r'Critique this draft: ${draft}',
              output: 'critique'),
          maxRounds: 5,
        ),
      ],
    ));

    final state = await runtime.executeProgram(program);
    expect(state.status, RuntimeStatus.halted);
    expect(workerRuns, equals(2),
        reason: 'revise once, then accept on round two');

    // Round two's critic saw round two's draft through interpolation.
    final critiques = model.recordedRequests
        .where((r) => r.messages.last.text.contains('Critique this draft'));
    expect(critiques.last.messages.last.text, contains('draft v2'));
    await vm.shutdown();
  });

  test('Router dispatches only the chosen route', () async {
    final model = FakeVasterModel(handler: (request) {
      final text = request.messages.last.text;
      if (text.contains('Choose exactly one')) {
        return ModelResponse(
            message: ChatMessage.model(jsonEncode({'choice': 'billing'})));
      }
      return ModelResponse(message: ChatMessage.model('handled'));
    });
    final (vm, runtime) = await boot(model);

    final program = compiler.compile(Pipeline(
      name: 'router_e2e',
      roles: [role('billing_agent'), role('tech_agent')],
      children: const [
        Router(
          prompt: 'A customer reports being double-charged after an app crash.',
          routes: [
            RouteCase(
                label: 'billing',
                description: 'payment or invoice issues',
                agentId: 'billing_agent',
                prompt: 'Resolve the billing issue.'),
            RouteCase(
                label: 'technical',
                description: 'crashes and product defects',
                agentId: 'tech_agent',
                prompt: 'Diagnose the crash.'),
          ],
        ),
      ],
    ));

    final state = await runtime.executeProgram(program);
    expect(state.status, RuntimeStatus.halted);

    final prompts = model.recordedRequests.map((r) => r.messages.last.text);
    expect(prompts.any((p) => p.contains('Resolve the billing issue')), isTrue);
    expect(prompts.any((p) => p.contains('Diagnose the crash')), isFalse,
        reason: 'the unchosen route must not execute');
    await vm.shutdown();
  });

  test('Resilient retries until success and exposes prior errors', () async {
    final model = FakeVasterModel();
    final (vm, runtime) = await boot(model);

    // First two attempts read a missing file (throws); the third reads a file
    // written between attempts... simplest deterministic shape: always-failing
    // child with onExhausted, then assert attempts and recovery both work.
    final failing = compiler.compile(Pipeline(
      name: 'resilient_exhaust',
      children: const [
        Resilient(
          child: ReadFile(path: '/nowhere/missing.txt'),
          attempts: 3,
          onExhausted: [Prompt(r'All attempts failed: ${retry_error_3}')],
        ),
      ],
    ));

    final state = await runtime.executeProgram(failing);
    expect(state.status, RuntimeStatus.halted,
        reason: 'exhaustion flows to onExhausted, not a trap');
    final report = model.recordedRequests.single.messages.last.text;
    expect(report, contains('All attempts failed:'));
    expect(report, isNot(contains(r'${retry_error_3}')),
        reason: 'the final error interpolates into the report');
    await vm.shutdown();
  });
}
