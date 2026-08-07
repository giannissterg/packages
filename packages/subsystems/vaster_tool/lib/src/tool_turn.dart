import 'package:vaster_model/vaster_model.dart';

import 'tool_call_gate.dart';
import 'tool_effect_recorder.dart';
import 'tool_result.dart';

/// The batch of tool calls a model emitted in ONE assistant turn — a
/// first-class concept, not a bare `List<FunctionCallPart>` (a list of T
/// is its own feature): the turn owns the batching rule both providers
/// require (all responses from one turn travel together in a single
/// tool-role message) and the claim-order determinism the effect ledger
/// needs.
final class ToolTurn {
  final List<FunctionCallPart> calls;

  const ToolTurn(this.calls);

  bool get isEmpty => calls.isEmpty;
  int get length => calls.length;
}

/// How the calls within one turn execute. Typed, not a bool (Rule 11):
/// the ISA loop serializes (VFS write ordering), the agent loop
/// parallelizes — a deliberate, declared difference instead of two
/// hand-rolled loops that happen to differ.
enum ToolTurnConcurrency { sequential, parallel }

/// One call's fate within a turn — sealed, carrying its result (Rule 2):
/// consumers derive telemetry, quota accounting, and transcripts from
/// the type, never from side-channel flags.
sealed class ToolCallExecution {
  final ToolResult result;
  const ToolCallExecution(this.result);
}

/// The tool really ran.
final class ExecutedCall extends ToolCallExecution {
  const ExecutedCall(super.result);
}

/// The effect recorder replayed a recorded result — no side effect was
/// re-performed (REL-P4/GAP-3a).
final class ReplayedCall extends ToolCallExecution {
  const ReplayedCall(super.result);
}

/// The outcome of one whole turn: per-call executions in call order,
/// plus the turn-level semantics both loops used to hand-roll.
final class ToolTurnOutcome {
  final List<ToolCallExecution> executions;

  const ToolTurnOutcome(this.executions);

  /// Calls that really executed — the number quota accounting charges
  /// (replays perform no work).
  int get executedCount => executions.whereType<ExecutedCall>().length;

  int get replayedCount => executions.whereType<ReplayedCall>().length;

  /// The single tool-role message providers require: all of one turn's
  /// responses together, in call order. This rule lived as a duplicated
  /// comment in two loops; now it is a property of the type.
  ChatMessage toToolMessage() =>
      ChatMessage(role: Role.tool, parts: [for (final e in executions) e.result.toResponsePart()]);
}

/// Runs a [ToolTurn] through the guarded, effect-recorded pipeline —
/// pure composition over its three seams (gate, recorder, dispatch), so
/// the runtime's ISA loop and the agent loop are the SAME machinery with
/// different collaborators, never two loops.
///
/// Order contract: gates and effect claims are taken SEQUENTIALLY in
/// call order regardless of [concurrency] (deterministic occurrence
/// identity); only the dispatch of non-replayed calls parallelizes when
/// [ToolTurnConcurrency.parallel] is declared. A gate refusal throws
/// before anything in the turn dispatches.
final class ToolTurnRunner {
  final ToolCallGate gate;
  final ToolEffectRecorder recorder;

  /// Executes one permitted, non-replayed call (the variable part: the
  /// ISA loop's VFS-first dispatch vs the agent's tool-table dispatch).
  final Future<ToolResult> Function(FunctionCallPart call) dispatch;

  final ToolTurnConcurrency concurrency;

  const ToolTurnRunner({
    required this.gate,
    required this.recorder,
    required this.dispatch,
    required this.concurrency,
  });

  Future<ToolTurnOutcome> run(ToolTurn turn, {required EffectRegion region}) async {
    // Phase 1 — sequential, in call order: every call is gated and its
    // effect slot claimed BEFORE anything dispatches.
    final plans = <({FunctionCallPart call, ToolEffectClaim claim})>[];
    for (final call in turn.calls) {
      gate.permit(call.name);
      plans.add((
        call: call,
        claim: recorder.claim(
          region: region,
          name: call.name,
          arguments: call.arguments,
          callId: call.callId,
        ),
      ));
    }

    // Phase 2 — execute the misses (sequentially or in parallel), commit
    // successes, replay the hits.
    Future<ToolCallExecution> settle(({FunctionCallPart call, ToolEffectClaim claim}) plan) async {
      switch (plan.claim) {
        case ToolEffectReplay(:final result):
          return ReplayedCall(ToolResult(callId: plan.call.callId, name: plan.call.name, response: result));
        case ToolEffectSlot slot:
          final result = await dispatch(plan.call);
          return ExecutedCall(
            result.isError
                ? result
                : ToolResult(
                    callId: result.callId,
                    name: result.name,
                    response: recorder.commit(slot, result.response),
                    executionDuration: result.executionDuration,
                  ),
          );
        case ToolEffectInert():
          return ExecutedCall(await dispatch(plan.call));
      }
    }

    final executions = switch (concurrency) {
      ToolTurnConcurrency.parallel => await Future.wait(plans.map(settle)),
      ToolTurnConcurrency.sequential => [for (final plan in plans) await settle(plan)],
    };
    return ToolTurnOutcome(executions);
  }
}
