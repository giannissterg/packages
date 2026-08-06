import 'dart:convert';

import 'package:vaster_metering/vaster_metering.dart';
import 'package:vaster_model/vaster_model.dart';
import 'package:vaster_token_estimate/vaster_token_estimate.dart';
import 'package:vaster_vm_api/vaster_vm_api.dart';

/// Resolves one [DecideOp] decision: asks the model to choose among labeled
/// branches and returns the parsed outcome.
///
/// This is model-orchestration concern, not instruction dispatch — the same
/// separation as [ToolCallOrchestrator]. The arbiter owns its collaborators at
/// construction (VM, budget); everything on [decide] is genuinely
/// per-invocation state (active model, session, cache hints, and the branch
/// menu). It deliberately never sees program counters: branch *labels* go in,
/// a chosen label comes out, and the engine owns the control transfer.
///
/// Routing through the active session appends the decision turn to the
/// session's history — intentional, so the agent remembers what it chose and
/// why on subsequent turns.
final class DecisionArbiter {
  final VasterVirtualMachine vm;

  /// The runtime's shared metering pipeline (host budget + program quota).
  final ModelCallMeter meter;

  const DecisionArbiter({
    required this.vm,
    required this.meter,
  });

  /// Asks the model to pick one of [branches] for [prompt].
  ///
  /// Returns the chosen `label` (null when the answer resolved to no branch
  /// label) and the model's `rationale` when it provided one.
  Future<({String? label, String? rationale})> decide({
    required String prompt,
    required List<({String label, String description})> branches,
    VasterModel? model,
    String? sessionId,
    List<ContextCacheHint> cacheHints = const [],
  }) async {
    final labels = [for (final b in branches) b.label];
    final menu = branches
        .map((b) => '- ${b.label}: ${b.description}')
        .join('\n');
    final composed = '$prompt\n\n'
        'Choose exactly one of the following options:\n$menu\n\n'
        'Answer as JSON: {"choice": "<label>", "rationale": "<why>"}';

    final schema = {
      'type': 'object',
      'properties': {
        'choice': {'type': 'string', 'enum': labels},
        'rationale': {'type': 'string'},
      },
      'required': ['choice'],
      'additionalProperties': false,
    };
    final config = GenerationConfig(responseSchema: schema);

    final response = sessionId != null
        ? await vm.promptInSession(sessionId, composed,
            model: model, config: config, cacheHints: cacheHints)
        : await vm.prompt(composed,
            model: model, config: config, cacheHints: cacheHints);

    meter.charge(
      usage: response.usage.totalTokenCount > 0
          ? response.usage
          : TokenEstimate.forExchange(prompt: composed, output: response.text),
      modelName: (model ?? vm.config.defaultModel).modelName,
      callSite: 'isa_decide',
    );

    return _parse(response.text, labels);
  }

  /// Tolerant outcome parsing: strip markdown fences → JSON `choice` →
  /// bare-label fallback. Labels match exact-first, then case-insensitively.
  ({String? label, String? rationale}) _parse(String text, List<String> labels) {
    var body = text.trim();
    if (body.startsWith('```')) {
      final lines = body.split('\n');
      if (lines.length > 1) {
        final withoutFirst = lines.sublist(1);
        if (withoutFirst.isNotEmpty && withoutFirst.last.trim() == '```') {
          withoutFirst.removeLast();
        }
        body = withoutFirst.join('\n').trim();
      }
    }

    String? choice;
    String? rationale;
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map) {
        choice = decoded['choice']?.toString();
        rationale = decoded['rationale']?.toString();
      }
    } on FormatException {
      // Weak backends may answer with the bare label instead of JSON.
      choice = body;
    }

    if (choice == null) return (label: null, rationale: rationale);
    if (labels.contains(choice)) return (label: choice, rationale: rationale);
    final lower = choice.toLowerCase().trim();
    for (final label in labels) {
      if (label.toLowerCase() == lower) return (label: label, rationale: rationale);
    }
    return (label: null, rationale: rationale);
  }
}
