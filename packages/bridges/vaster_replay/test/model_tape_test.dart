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
    DecideOp(
        prompt: r'Escalate? Summary: ${summary}',
        branches: [
          DecisionBranch(label: 'escalate', description: 'page a human', targetPc: 3),
          DecisionBranch(label: 'resolve', description: 'auto-resolve', targetPc: 5),
        ],
        outputVar: 'verdict'),
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
            message: ChatMessage.model(jsonEncode({'choice': 'escalate', 'rationale': 'sev1 signature'})));
      }
      return ModelResponse(message: ChatMessage.model('DB failover storm in us-east.'));
    });
    final tape = ModelTape();
    final recorder = RecordingVasterModel(inner: live, tape: tape);

    final (recorded, vm1) = await run(recorder);
    expect(recorded.status, RuntimeStatus.halted);
    expect(recorded.registers['escalated'], isTrue);
    expect(tape.length, equals(2), reason: 'one prompt + one decision');
    await vm1.shutdown();

    // The tape survives serialization (this is what CI would load).
    final rehydrated = ModelTape.fromJson(jsonDecode(jsonEncode(tape.toJson())) as Map<String, dynamic>);

    // Replay: no live model anywhere.
    final replayModel = ReplayVasterModel(tape: rehydrated);
    final (replayed, vm2) = await run(replayModel);

    expect(replayed.status, RuntimeStatus.halted);
    expect(replayed.registers['escalated'], isTrue, reason: 'the recorded decision path is reproduced');
    expect(replayed.registers['summary'], equals('DB failover storm in us-east.'));
    expect(replayed.registers['verdict'], equals('escalate'));
    expect(replayModel.remaining, equals(0), reason: 'a faithful replay drains the tape');
    await vm2.shutdown();
  });

  test('recorded usage and JSON-safe rawResponse survive the tape', () async {
    final live = FakeVasterModel(handler: (request) {
      return ModelResponse(
        message: ChatMessage.model('measured reply'),
        usage: const UsageMetadata(
          promptTokenCount: 1234,
          candidatesTokenCount: 56,
          cacheReadTokenCount: 1000,
          costUsd: 0.0123,
          source: UsageSource.measured,
        ),
        rawResponse: const {'total_cost_usd': 0.0123, 'provider': 'test'},
      );
    });
    final tape = ModelTape();
    final recorder = RecordingVasterModel(inner: live, tape: tape);
    await recorder.generate(ModelRequest(messages: [ChatMessage.user('hi')]));

    final rehydrated = ModelTape.fromJson(jsonDecode(jsonEncode(tape.toJson())) as Map<String, dynamic>);
    final replayed =
        await ReplayVasterModel(tape: rehydrated).generate(ModelRequest(messages: [ChatMessage.user('hi')]));

    expect(replayed.usage.promptTokenCount, equals(1234));
    expect(replayed.usage.cacheReadTokenCount, equals(1000));
    expect(replayed.usage.costUsd, equals(0.0123));
    expect(replayed.usage.source, equals(UsageSource.measured));
    expect((replayed.rawResponse as Map)['provider'], equals('test'));
  });

  test('the tape carries the backend capabilities that shaped its requests', () async {
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
    final rehydrated = ModelTape.fromJson(jsonDecode(jsonEncode(tape.toJson())) as Map<String, dynamic>);
    final replay = ReplayVasterModel(tape: rehydrated);
    expect(replay.capabilities.maxContextTokens, equals(200000));
    expect(replay.capabilities.maxOutputTokens, equals(8192));
    expect(replay.capabilities.maxContextTokens, greaterThan(replay.capabilities.maxOutputTokens),
        reason: 'output reservation must never consume the whole window — '
            'that starves context compilation to zero messages');
    expect(replay.modelName, contains(live.modelName));
  });

  test('fingerprints render as stable positive hex', () {
    final fingerprint = ModelTape.fingerprintOf(ModelRequest(messages: [ChatMessage.user('any request')]));
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
          responseJson: ModelResponse(message: ChatMessage.model(text)).toJson(),
        ),
    ]);
    final replay = ReplayVasterModel(tape: tape);

    expect((await replay.generate(request)).text, equals('first answer'));
    expect((await replay.generate(request)).text, equals('second answer'));
  });

  test('a diverged run fails fast — as typed data, not a message string', () async {
    final live = FakeVasterModel(defaultResponseText: 'recorded output');
    final tape = ModelTape();
    final (_, vm1) = await run(RecordingVasterModel(inner: live, tape: tape));
    await vm1.shutdown();

    final replay = ReplayVasterModel(tape: tape);
    await expectLater(
      replay.generate(ModelRequest(messages: [ChatMessage.user('a request that never happened')])),
      throwsA(isA<TapeDivergenceException>()
          .having((e) => e.callIndex, 'callIndex', 0)
          .having((e) => e.liveRequest.messages.single.text, 'live request', 'a request that never happened')
          .having((e) => e.unconsumed, 'unconsumed', isNotEmpty)
          .having((e) => e.toString(), 'rendering', contains('Replay diverged'))),
    );
  });

  test(
      'v2 recording carries the full request; v1 entries read as '
      'preview-only', () async {
    final live = FakeVasterModel(defaultResponseText: 'recorded output');
    final tape = ModelTape();
    final (_, vm) = await run(RecordingVasterModel(inner: live, tape: tape));
    await vm.shutdown();

    // Recording is v2: every entry carries the full request.
    for (final entry in tape.entries) {
      final recorded = entry.recorded;
      expect(recorded, isA<FullRecordedRequest>());
      final hydrated = (recorded as FullRecordedRequest).toRequest();
      expect(hydrated.messages, isNotEmpty);
    }
    expect(tape.toJson()['version'], ModelTape.formatVersion);

    // A v1 round-trip (no `request` field) degrades to preview-only —
    // the sealed type forces consumers to handle it.
    final v1Json = tape.toJson();
    for (final e in (v1Json['entries'] as List)) {
      (e as Map).remove('request');
    }
    final v1 = ModelTape.fromJson(Map<String, dynamic>.from(v1Json));
    expect(v1.entries.first.recorded, isA<PreviewOnlyRequest>());
    // …and still replays: fingerprints are the cross-version contract.
    final replay = ReplayVasterModel(tape: v1);
    final (_, vm2) = await run(replay);
    await vm2.shutdown();
    expect(replay.remaining, 0, reason: 'v1 tape fully consumed');
  });
}
