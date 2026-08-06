import 'package:vaster_instruction/vaster_instruction.dart';
import 'package:vaster_events/vaster_events.dart';
import 'package:vaster_machine_state/vaster_machine_state.dart';
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
class HitlController implements MachineStateComponent {
  /// The bus HITL pause events publish on — owned for the controller's
  /// lifetime (Rule 5: an owned concern is a constructor parameter, never
  /// a per-invocation one).
  final RuntimeEventBus eventBus;

  HitlController({required this.eventBus});

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
      registers.write(
          hitlStatusRegister(req.outputVar!), response.status.isAffirmative);
    }
    _pendingRequest = null;
    return 1; // advance past YieldHumanInteractionOp
  }

  /// Clears all HITL state (e.g. on program start).
  void clear() => _pendingRequest = null;

  @override
  String get stateKey => 'hitl';

  @override
  Map<String, dynamic> captureState() => {
        if (_pendingRequest != null)
          'pendingRequest': _pendingRequest!.toJson(),
      };

  @override
  void restoreState(Map<String, dynamic> snapshot) {
    final pending = snapshot['pendingRequest'];
    _pendingRequest = pending == null
        ? null
        : HumanInteractionRequest.fromJson(
            Map<String, dynamic>.from(pending as Map));
  }
}
