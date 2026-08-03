import 'package:vaster_instruction/vaster_instruction.dart';
import 'package:vaster_events/vaster_events.dart';
import 'register_file.dart';
import 'runtime_status.dart';

/// Manages the Human-in-the-Loop (HITL) lifecycle for a running [VasterRuntime].
///
/// Owns all HITL state transitions:
/// - Yielding execution when a [YieldHumanInteractionOp] is encountered.
/// - Consuming a [HumanInteractionResponse] to resume execution.
/// - Clearing state on program reset.
///
/// By centralising these transitions, [VasterRuntime] avoids duplicating
/// mutation logic across [executeProgram], [resumeWithHumanResponse],
/// and [restoreAndResume].
class HitlController {
  HumanInteractionRequest? _pendingRequest;

  /// The pending human interaction request, or null if not currently paused.
  HumanInteractionRequest? get pendingRequest => _pendingRequest;

  /// Whether the runtime is currently waiting for a human response.
  bool get isPending => _pendingRequest != null;

  /// Called by [YieldHumanInteractionOp] to pause the runtime.
  ///
  /// Stores [request] as the pending interaction, publishes a
  /// [HumanInteractionRequiredEvent] on [eventBus], and returns
  /// [RuntimeStatus.pausedForHuman] for the caller to set.
  RuntimeStatus pause({
    required HumanInteractionRequest request,
    required RuntimeEventBus eventBus,
    required int currentPc,
  }) {
    _pendingRequest = request;
    eventBus.publish(HumanInteractionRequiredEvent(
      eventId: 'evt_hitl_$currentPc',
      request: request.toJson(),
    ));
    return RuntimeStatus.pausedForHuman;
  }

  /// Restores a pending request from a continuation snapshot without publishing
  /// an event (used during [restoreAndResume]).
  void restorePending(HumanInteractionRequest? request) {
    _pendingRequest = request;
  }

  /// Consumes [response], writing the human's answer into [registers].
  ///
  /// Returns the number of PC positions to advance (always 1 — past the
  /// [YieldHumanInteractionOp] that caused the pause).
  ///
  /// Throws [StateError] if called with no pending request.
  int consume({
    required HumanInteractionResponse response,
    required RegisterFile registers,
  }) {
    final req = _pendingRequest;
    if (req == null) {
      throw StateError('HitlController.consume: no pending human interaction request.');
    }
    if (req.outputVar != null) {
      registers.write(req.outputVar!, response.value);
      registers.write('${req.outputVar!}_status', response.status.name);
    }
    _pendingRequest = null;
    return 1; // advance past YieldHumanInteractionOp
  }

  /// Clears all HITL state (e.g. on program start).
  void clear() => _pendingRequest = null;
}
