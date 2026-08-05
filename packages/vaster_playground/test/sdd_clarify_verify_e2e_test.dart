import 'dart:convert';

import 'package:test/test.dart';
import 'package:vaster_ast/vaster_ast.dart';
import 'package:vaster_compiler/vaster_compiler.dart';
import 'package:vaster_domain/vaster_domain.dart';
import 'package:vaster_model_fake/vaster_model_fake.dart';
import 'package:vaster_vm/vaster_vm.dart';

/// E2E for the SDD cycle's two new ends: Clarify (HITL requirements
/// gathering) and Verify (judged sandbox verification).
void main() {
  const analyst = AgentRole(
      roleId: 'analyst', name: 'Analyst', title: 'Requirements Analyst',
      instruction: 'You gather requirements.');

  test('Clarify asks until the model is satisfied, folding human answers',
      () async {
    var questionsAsked = 0;
    final model = FakeVasterModel(handler: (request) {
      final text = request.messages.last.text;
      if (text.contains('Choose exactly one')) {
        return ModelResponse(
          message: ChatMessage.model(jsonEncode(
              {'choice': questionsAsked < 2 ? 'ask' : 'ready'})),
        );
      }
      if (text.contains('Ask the single most important')) {
        questionsAsked++;
        return ModelResponse(
            message: ChatMessage.model('Question $questionsAsked: what about '
                '${questionsAsked == 1 ? 'refunds' : 'currencies'}?'));
      }
      if (text.contains('Update the clarification notes')) {
        // Fold: echo the running notes plus the new Q/A pair.
        final q = RegExp(r'Q: (.*)').firstMatch(text)?.group(1) ?? '';
        final a = RegExp(r'A: (.*)').firstMatch(text)?.group(1) ?? '';
        return ModelResponse(
            message: ChatMessage.model('NOTES(v$questionsAsked) $q -> $a'));
      }
      return ModelResponse(message: ChatMessage.model('ack'));
    });

    final vm = await VasterVMEngine.bootstrap(
        config: VMConfig(defaultModel: model));
    final runtime = VasterRuntime(
      vm: vm,
      policy: ExecutionPolicy.unlimited,
      budget: ExecutionBudget.unlimited(),
      scheduler: BasicVasterScheduler(taskQueue: PriorityTaskQueue()),
    );

    final program = const BasicWorkflowCompiler().compile(Pipeline(
      name: 'clarify_e2e',
      roles: const [analyst],
      children: const [
        Clarify(topic: 'billing requirements', agent: analyst, maxQuestions: 5),
        Output(from: Binding('clarifications')),
      ],
    ));

    var state = await runtime.executeProgram(program);

    // Round 1: paused on the interpolated question.
    expect(state.status, RuntimeStatus.pausedForHuman);
    expect(runtime.pendingHumanRequest!.prompt,
        equals('Question 1: what about refunds?'),
        reason: 'the HITL prompt is the model-generated question');
    state = await runtime.resumeWithHumanResponse(
        HumanInteractionResponse.answer(
            requestId: 'clarify', answerText: 'Full refunds within 30 days.'));

    // Round 2.
    expect(state.status, RuntimeStatus.pausedForHuman);
    expect(runtime.pendingHumanRequest!.prompt, contains('currencies'));
    state = await runtime.resumeWithHumanResponse(
        HumanInteractionResponse.answer(
            requestId: 'clarify', answerText: 'USD and EUR only.'));

    // The model declares ready; the folded notes are the phase's value.
    expect(state.status, RuntimeStatus.halted);
    expect(questionsAsked, equals(2));
    final notes = '${state.registers['__output__']}';
    expect(notes, contains('NOTES(v2)'));
    expect(notes, contains('USD and EUR only.'),
        reason: 'human answers are folded into the clarification notes');

    await vm.shutdown();
  });

  test('Verify routes pass and fail through the judged verdict', () async {
    Future<(String verdictTaken, String verdict)> runVerify(
        String sandboxOutput) async {
      final model = FakeVasterModel(handler: (request) {
        final text = request.messages.last.text;
        if (text.contains('Choose exactly one')) {
          final passed = text.contains('OK:');
          return ModelResponse(
              message: ChatMessage.model(
                  jsonEncode({'choice': passed ? 'pass' : 'fail'})));
        }
        return ModelResponse(message: ChatMessage.model('ack: $text'));
      });
      final vm = await VasterVMEngine.bootstrap(
          config: VMConfig(defaultModel: model, rootMountPath: '/workspace'));
      vm.registerSandbox(IsolateCodeSandbox(
        descriptor: const SandboxDescriptor(
            sandboxId: 'ci_box', type: 'isolate', description: 'CI sandbox'),
        evaluator: (code, inputs) => sandboxOutput,
      ));
      final runtime = VasterRuntime(
        vm: vm,
        policy: ExecutionPolicy.unlimited,
        budget: ExecutionBudget.unlimited(),
        scheduler: BasicVasterScheduler(taskQueue: PriorityTaskQueue()),
      );

      final program = const BasicWorkflowCompiler().compile(Pipeline(
        name: 'verify_e2e',
        children: const [
          Verify(
            run: 'dart test',
            envId: 'ci_box',
            onPass: [Prompt('announce the release')],
            onFail: [Prompt('open a remediation task')],
          ),
        ],
      ));

      final state = await runtime.executeProgram(program);
      expect(state.status, RuntimeStatus.halted);

      final followUp = model.recordedRequests
          .map((r) => r.messages.last.text)
          .where((t) =>
              t.contains('announce the release') ||
              t.contains('open a remediation task'))
          .single;
      final artifact = await vm.fileSystemManager
          .resolveFileSystem('/workspace/verification.md')
          .readText('/workspace/verification.md');
      expect(artifact, contains(sandboxOutput),
          reason: 'the run output is the verification artifact');
      final verdict = '${state.registers['verification_verdict']}';
      await vm.shutdown();
      return (followUp, verdict);
    }

    final (passPath, passVerdict) = await runVerify('OK: all 12 tests passed');
    expect(passPath, contains('announce the release'));
    expect(passVerdict, equals('pass'));

    final (failPath, failVerdict) = await runVerify('FAILED: 3 of 12 tests');
    expect(failPath, contains('open a remediation task'));
    expect(failVerdict, equals('fail'));
  });
}
