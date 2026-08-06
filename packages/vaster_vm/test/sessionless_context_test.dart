import 'package:test/test.dart';
import 'package:vaster_model_fake/vaster_model_fake.dart';
import 'package:vaster_vm/vaster_vm.dart';

/// Sessionless prompts carry the compiled global context — the gap the
/// KV prefix validation caught live: `vaster run`'s plain `PromptOp`s
/// sent ONLY the turn text, so pinned `Knowledge` never reached the
/// model on any backend.
void main() {
  late FakeVasterModel model;
  late VasterVMEngine vm;

  setUp(() async {
    model = FakeVasterModel();
    vm = await VasterVMEngine.bootstrap(config: VMConfig(defaultModel: model));
  });
  tearDown(() => vm.shutdown());

  void installKnowledge() {
    vm.contextManager.addRegion(ContextRegion(
      id: 'facts',
      label: 'story facts',
      classId: 'knowledge',
      messages: [ChatMessage.user('Story facts: Bo is a small brown dog.')],
      estimatedTokens: 12,
    ));
    vm.contextManager.pinRegion('facts');
  }

  test('prompt() prepends compiled regions to the turn', () async {
    installKnowledge();
    await vm.prompt('Continue the story of Bo.');

    final request = model.recordedRequests.single;
    expect(request.messages, hasLength(2));
    expect(request.messages.first.text, contains('Story facts'),
        reason: 'the pinned region leads the prompt — the KV-reuse '
            'alignment contract depends on stable-content-first');
    expect(request.messages.last.text, 'Continue the story of Bo.');
  });

  test('promptWithHistory() prepends compiled regions to the transcript',
      () async {
    installKnowledge();
    await vm.promptWithHistory([
      ChatMessage.user('turn one'),
      ChatMessage.model('reply one'),
      ChatMessage.user('turn two'),
    ]);

    final request = model.recordedRequests.single;
    expect(request.messages, hasLength(4));
    expect(request.messages.first.text, contains('Story facts'));
    expect(request.messages.last.text, 'turn two');
  });

  test('promptStream() carries the compiled regions too', () async {
    installKnowledge();
    await vm.promptStream('Continue the story of Bo.').drain<void>();

    // The fake's stream path records via its inner generate too — take
    // the last recorded request rather than assuming exactly one.
    final request = model.recordedRequests.last;
    expect(request.messages.first.text, contains('Story facts'));
  });

  test('system-class regions land in systemInstruction, not messages',
      () async {
    vm.contextManager.addRegion(ContextRegion(
      id: 'sys',
      label: 'persona',
      classId: 'system',
      messages: [ChatMessage.system('You are a storyteller.')],
      estimatedTokens: 8,
    ));
    vm.contextManager.pinRegion('sys');
    await vm.prompt('hello');

    final request = model.recordedRequests.single;
    expect(request.systemInstruction?.text, contains('storyteller'));
    expect(request.messages.single.text, 'hello');
  });

  test('with no regions installed, requests are unchanged', () async {
    await vm.prompt('bare prompt');
    final request = model.recordedRequests.single;
    expect(request.systemInstruction, isNull);
    expect(request.messages.single.text, 'bare prompt');
  });
}
