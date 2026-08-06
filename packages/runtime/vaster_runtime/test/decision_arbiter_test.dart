import 'package:test/test.dart';
import 'package:vaster_metering/vaster_metering.dart';
import 'package:vaster_model/vaster_model.dart';
import 'package:vaster_model_fake/vaster_model_fake.dart';
import 'package:vaster_pricing/vaster_pricing.dart';
import 'package:vaster_runtime/vaster_runtime.dart';
import 'package:vaster_vm_api/vaster_vm_api.dart';

/// The point of the [PromptFunnel] facet, made concrete: an arbiter test
/// double implements the four turn verbs — not the 26-member master VM
/// interface. If this fake ever needs a fifth member, the arbiter's scope
/// has crept.
final class _CannedFunnel implements PromptFunnel {
  final String answer;
  int calls = 0;
  String? lastSessionId;

  _CannedFunnel(this.answer);

  ModelResponse get _response =>
      ModelResponse(message: ChatMessage.model(answer));

  @override
  Future<ModelResponse> prompt(String promptText,
      {VasterModel? model,
      GenerationConfig? config,
      CancellationToken? cancelToken,
      List<ContextCacheHint>? cacheHints}) async {
    calls++;
    return _response;
  }

  @override
  Future<ModelResponse> promptInSession(String sessionId, String promptText,
      {VasterModel? model,
      GenerationConfig? config,
      CancellationToken? cancelToken,
      List<ContextCacheHint>? cacheHints}) async {
    calls++;
    lastSessionId = sessionId;
    return _response;
  }

  @override
  Future<ModelResponse> promptWithHistory(List<ChatMessage> messages,
          {VasterModel? model,
          List<ToolDefinition>? tools,
          GenerationConfig? config,
          CancellationToken? cancelToken,
          List<ContextCacheHint>? cacheHints}) =>
      throw UnimplementedError('the arbiter never sends transcripts');

  @override
  Stream<ModelResponseChunk> promptStream(String promptText,
          {VasterModel? model,
          GenerationConfig? config,
          CancellationToken? cancelToken,
          List<ContextCacheHint>? cacheHints}) =>
      throw UnimplementedError('the arbiter never streams');
}

void main() {
  DecisionArbiter arbiter(String cannedAnswer, {_CannedFunnel? funnel}) =>
      DecisionArbiter(
        funnel: funnel ?? _CannedFunnel(cannedAnswer),
        meter: ModelCallMeter(
            pricingCatalog: PricingCatalog.builtin, sinks: const []),
        defaultModel: FakeVasterModel(),
      );

  const branches = [
    (label: 'ship', description: 'ship it'),
    (label: 'hold', description: 'wait'),
  ];

  group('DecisionArbiter sealed outcomes', () {
    test('a JSON choice resolves to DecisionChosen with rationale', () async {
      final outcome = await arbiter(
              '{"choice": "ship", "rationale": "tests are green"}')
          .decide(prompt: 'go?', branches: branches);
      expect(
          outcome,
          isA<DecisionChosen>()
              .having((d) => d.label, 'label', 'ship')
              .having((d) => d.rationale, 'rationale', 'tests are green'));
    });

    test('a fenced bare label resolves case-insensitively', () async {
      final outcome = await arbiter('```\nHOLD\n```')
          .decide(prompt: 'go?', branches: branches);
      expect(outcome, isA<DecisionChosen>().having((d) => d.label, 'label', 'hold'));
    });

    test('an unmatched answer is DecisionUnresolved carrying the raw text',
        () async {
      final outcome = await arbiter('let me think about it')
          .decide(prompt: 'go?', branches: branches);
      expect(
          outcome,
          isA<DecisionUnresolved>()
              .having((d) => d.rawAnswer, 'rawAnswer', 'let me think about it'));
    });

    test('a session id routes through promptInSession', () async {
      final funnel = _CannedFunnel('{"choice": "ship"}');
      await arbiter('', funnel: funnel).decide(
          prompt: 'go?', branches: branches, sessionId: 'sess_decide');
      expect(funnel.lastSessionId, 'sess_decide');
      expect(funnel.calls, 1);
    });
  });
}
