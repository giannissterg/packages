import 'package:vaster_instruction/vaster_instruction.dart';
import 'package:vaster_machine_state/vaster_machine_state.dart';

/// First-class, serializable snapshot of Vaster VM execution state at a
/// yield/trap boundary: identity metadata + the whole-machine
/// [MachineSnapshot].
///
/// v2 (machine-snapshot era): the five hand-copied projections of runtime
/// state the v1 continuation carried (registers, call stack, pending
/// request, session id, model descriptor) collapse into [machineState] —
/// the runtime's own component fold. A continuation can no longer be
/// missing a piece of machine state, because it does not enumerate machine
/// state at all.
class VasterContinuation {
  static const int currentFormatVersion = 2;

  final int formatVersion;
  final String continuationId;
  final String programName;

  /// The whole machine at the suspension boundary, keyed by component.
  final MachineSnapshot machineState;

  final DateTime suspendedAt;

  VasterContinuation({
    this.formatVersion = currentFormatVersion,
    required this.continuationId,
    required this.programName,
    required this.machineState,
    DateTime? suspendedAt,
  }) : suspendedAt = suspendedAt ?? DateTime.now();

  /// The instruction index execution resumes at.
  int get resumePc => machineState.pc;

  /// Convenience projection: the pending human-interaction request carried
  /// by the machine's HITL component, if any (hosts display it and validate
  /// `--respond` targets against it).
  HumanInteractionRequest? get pendingRequest {
    final pending = machineState.components['hitl']?['pendingRequest'];
    return pending == null
        ? null
        : HumanInteractionRequest.fromJson(Map<String, dynamic>.from(pending as Map));
  }

  Map<String, dynamic> toJson() => {
    'formatVersion': formatVersion,
    'continuationId': continuationId,
    'programName': programName,
    'machineState': machineState.toJson(),
    'suspendedAt': suspendedAt.toIso8601String(),
  };

  factory VasterContinuation.fromJson(Map<String, dynamic> json) {
    final version = (json['formatVersion'] as num?)?.toInt() ?? 1;
    if (version != currentFormatVersion) {
      throw FormatException(
        'Continuation format v$version is not supported by this build '
        '(speaks v$currentFormatVersion). v1 continuations predate the '
        'machine-snapshot era and cannot be resumed safely — they are '
        'missing machine state by construction.',
      );
    }
    return VasterContinuation(
      formatVersion: version,
      continuationId: json['continuationId'] as String? ?? '',
      programName: json['programName'] as String? ?? '',
      machineState: MachineSnapshot.fromJson(Map<String, dynamic>.from(json['machineState'] as Map)),
      suspendedAt: DateTime.tryParse(json['suspendedAt'] as String? ?? '') ?? DateTime.now(),
    );
  }
}
