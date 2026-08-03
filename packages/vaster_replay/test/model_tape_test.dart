import 'dart:convert';

import 'package:test/test.dart';
import 'package:vaster_model_fake/vaster_model_fake.dart';
import 'package:vaster_replay/vaster_replay.dart';
import 'package:vaster_vm/vaster_vm.dart';

/// Deterministic replay: record a run's model I/O, then reproduce the run
/// with zero live model calls — including a model-steered decision.
void main() {
  // 0: prompt (tool-free) -> 1: decide {left->3, right->5} -> ...
  const program = VasterProgram(programName: 'taped', instructions: [
    PromptOp(promptText: 'summarize the incident', outputVar: 'summary'),
    DecideOp(prompt: r'Escalate? Summary: ${summary}', branches: [
      DecisionBranch(label: 'escalate', description: 'page a human', targetPc: 3),
      DecisionBranch(label: 'resolve', description: 'auto-resolve', targetPc: 5),
    ], outputVar: 'verdict'),
    HaltOp(),
    SetRegisterOp(registerName: 'escalated', value: true),
    HaltOp(),
    SetRegisterOp(registerName: 'resolved', value: true),
    HaltOp(),
  ]);

  Future<(RuntimeState, VasterVirtualMachine)> run(VasterModel model) async {
    final vm = await VasterVMEngine.bootstrap(config: VMConfig(defaultModel: model));
    final runtime = VasterRuntime(
      vm: vm,
      policy: ExecutionPolicy.unlimited,
      budget: ExecutionBudget.unlimited(),
      scheduler: BasicVasterScheduler(taskQueue: PriorityTaskQueue()),
    );
    final state = await runtime.executeProgram(program);
    return (state, vm);
  }

  test('a recorded run replays identically with zero live model calls', () async {
    // Record: the live model summarizes then chooses to escalate.
    final live = FakeVasterModel(handler: (request) {
      final text = request.messages.last.text;
      if (text.contains('Choose exactly one')) {
        return ModelResponse(
            message: ChatMessage.model(jsonEncode(
                {'choice': 'escalate', 'rationale': 'sev1 signature'})));
      }
      return ModelResponse(
          message: ChatMessage.model('DB failover storm in us-east.'));
    });
    final tape = ModelTape();
    final recorder = RecordingVasterModel(inner: live, tape: tape);

    final (recorded, vm1) = await run(recorder);
    expect(recorded.status, RuntimeStatus.halted);
    expect(recorded.registers['escalated'], isTrue);
    expect(tape.length, equals(2), reason: 'one prompt + one decision');
    await vm1.shutdown();

    // The tape survives serialization (this is what CI would load).
    final rehydrated = ModelTape.fromJson(
        jsonDecode(jsonEncode(tape.toJson())) as Map<String, dynamic>);

    // Replay: no live model anywhere.
    final replayModel = ReplayVasterModel(tape: rehydrated);
    final (replayed, vm2) = await run(replayModel);

    expect(replayed.status, RuntimeStatus.halted);
    expect(replayed.registers['escalated'], isTrue,
        reason: 'the recorded decision path is reproduced');
    expect(replayed.registers['summary'], equals('DB failover storm in us-east.'));
    expect(replayed.registers['verdict'], equals('escalate'));
    expect(replayModel.remaining, equals(0),
        reason: 'a faithful replay drains the tape');
    await vm2.shutdown();
  });

  test('the tape carries the backend capabilities that shaped its requests',
      () async {
    // Regression: a session sizes its context compilation from the model's
    // capabilities, so replaying under different limits compiles different
    // messages and diverges. Found by a real claude-cli run — the fake-model
    // tests never exercised the session/agent request path.
    const recordedCaps = ModelCapabilities(
      maxContextTokens: 200000,
      maxOutputTokens: 8192,
      supportsStreaming: true,
      supportsFunctionCalling: false,
      supportsVision: true,
      supportsSystemInstruction: true,
      supportsReasoning: true,
    );
    final live = FakeVasterModel(capabilities: recordedCaps);
    final tape = ModelTape();
    RecordingVasterModel(inner: live, tape: tape);

    expect(tape.recordedCapabilities?.maxContextTokens, equals(200000));
    expect(tape.recordedCapabilities?.maxOutputTokens, equals(8192));
    expect(tape.recordedModelName, equals(live.modelName));

    // Survives serialization and is what replay presents.
    final rehydrated = ModelTape.fromJson(
        jsonDecode(jsonEncode(tape.toJson())) as Map<String, dynamic>);
    final replay = ReplayVasterModel(tape: rehydrated);
    expect(replay.capabilities.maxContextTokens, equals(200000));
    expect(replay.capabilities.maxOutputTokens, equals(8192));
    expect(replay.capabilities.maxContextTokens,
        greaterThan(replay.capabilities.maxOutputTokens),
        reason: 'output reservation must never consume the whole window — '
            'that starves context compilation to zero messages');
    expect(replay.modelName, contains(live.modelName));
  });

  test('fingerprints render as stable positive hex', () {
    final fingerprint = ModelTape.fingerprintOf(
        ModelRequest(messages: [ChatMessage.user('any request')]));
    expect(fingerprint, matches(RegExp(r'^[0-9a-f]{16}$')));
  });

  test('identical fingerprints replay in recorded order (FIFO)', () async {
    // The same request made twice must return the two recorded responses in
    // order — the loop-iteration case.
    final request = ModelRequest(messages: [ChatMessage.user('again')]);
    final tape = ModelTape(entries: [
      for (final text in ['first answer', 'second answer'])
        ModelTapeEntry(
          fingerprint: ModelTape.fingerprintOf(request),
          requestPreview: 'again',
          responseJson:
              ModelResponse(message: ChatMessage.model(text)).toJson(),
        ),
    ]);
    final replay = ReplayVasterModel(tape: tape);

    expect((await replay.generate(request)).text, equals('first answer'));
    expect((await replay.generate(request)).text, equals('second answer'));
  });

  test('a diverged run fails fast, naming the unmatched request', () async {
    final live = FakeVasterModel(defaultResponseText: 'recorded output');
    final tape = ModelTape();
    final (_, vm1) =
        await run(RecordingVasterModel(inner: live, tape: tape));
    await vm1.shutdown();

    final replay = ReplayVasterModel(tape: tape);
    await expectLater(
      replay.generate(ModelRequest(
          messages: [ChatMessage.user('a request that never happened')])),
      throwsA(isA<StateError>().having(
        (e) => e.message,
        'message',
        allOf(contains('Replay diverged'),
            contains('a request that never happened')),
      )),
    );
  });
}
