import 'dart:convert';

import 'package:vaster_metering/vaster_metering.dart';
import 'package:vaster_model/vaster_model.dart';
import 'package:vaster_token_estimate/vaster_token_estimate.dart';
import 'package:vaster_vm_api/vaster_vm_api.dart';

import 'decision_outcome.dart';

/// Resolves one [DecideOp] decision: asks the model to choose among labeled
/// branches and returns the parsed [DecisionOutcome].
///
/// This is model-orchestration concern, not instruction dispatch — the same
/// separation as [ToolCallOrchestrator]. The arbiter owns its collaborators at
/// construction — and holds exactly what its contract uses: the VM's
/// [PromptFunnel] facet (it converses with the model; it cannot mount
/// filesystems or shut the VM down, and now its type says so) and the
/// metering pipeline. The engine resolves the active model and passes it
/// in (Rule 5: no nullable-model fallback here); session, cache hints, and
/// the branch menu are the genuine per-call inputs. It deliberately never
/// sees program counters: branch *labels* go in, a sealed outcome comes
/// out, and the engine owns the control transfer.
///
/// Routing through the active session appends the decision turn to the
/// session's history — intentional, so the agent remembers what it chose and
/// why on subsequent turns.
final class DecisionArbiter {
  /// The VM's model-turn facet — the only VM capability this component needs.
  final PromptFunnel funnel;

  /// The runtime's shared metering pipeline (host budget + program quota).
  final ModelCallMeter meter;

  const DecisionArbiter({required this.funnel, required this.meter});

  /// Asks the model to pick one of [branches] for [prompt].
  Future<DecisionOutcome> decide({
    required String prompt,
    required List<({String label, String description})> branches,
    required VasterModel model,
    String? sessionId,
    List<ContextCacheHint> cacheHints = const [],
  }) async {
    final labels = [for (final b in branches) b.label];
    final menu = branches.map((b) => '- ${b.label}: ${b.description}').join('\n');
    final composed =
        '$prompt\n\n'
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
        ? await funnel.promptInSession(
            sessionId,
            composed,
            model: model,
            config: config,
            cacheHints: cacheHints,
          )
        : await funnel.prompt(composed, model: model, config: config, cacheHints: cacheHints);

    meter.charge(
      usage: response.usage.totalTokenCount > 0
          ? response.usage
          : TokenEstimate.forExchange(prompt: composed, output: response.text),
      modelName: response.servedBy ?? model.modelName,
      callSite: 'isa_decide',
    );

    return _parse(response.text, labels);
  }

  /// Tolerant outcome parsing: strip markdown fences → JSON `choice` →
  /// bare-label fallback. Labels match exact-first, then case-insensitively.
  /// An answer matching no label is [DecisionUnresolved] carrying the raw
  /// text — the engine decides whether a default branch absorbs it.
  DecisionOutcome _parse(String text, List<String> labels) {
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

    if (choice != null) {
      if (labels.contains(choice)) {
        return DecisionChosen(label: choice, rationale: rationale);
      }
      final lower = choice.toLowerCase().trim();
      for (final label in labels) {
        if (label.toLowerCase() == lower) {
          return DecisionChosen(label: label, rationale: rationale);
        }
      }
    }
    return DecisionUnresolved(rawAnswer: text, rationale: rationale);
  }
}
