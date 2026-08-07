import 'package:vaster_machine_state/vaster_machine_state.dart';
import 'package:vaster_model/vaster_model.dart';

/// The ambient environment the instruction stream executes under: active
/// session, active model, program-registered toolset, and the error-handler
/// stack.
///
/// These four used to be loose private fields on the runtime — and every one
/// of them was silently lost by the first checkpoint implementation, while
/// the componentized state (`RegisterFile`, `CallStack`) survived on the
/// first try. One component, one snapshot, one restore.
///
/// The model is stored as its **descriptor** — the live [VasterModel] object
/// is derived state, resolved through the VM's registry on use. Live objects
/// are never machine state (Rule 1: descriptors and handles only).
final class MachineContext implements MachineStateComponent {
  String? activeSessionId;
  ModelDescriptor? activeModelDescriptor;

  /// Ordered fallback chain after [activeModelDescriptor] (REL-P3) —
  /// descriptors, never live models, same as the active descriptor itself.
  List<ModelDescriptor> activeModelFallbacks = const [];

  List<ToolDefinition> programToolSet = const [];
  final List<ErrorHandlerFrame> errorHandlers = [];

  /// Monotonic event-id sequence (A5). Machine state, so ids stay unique
  /// across a checkpoint resume and deterministic under replay — a bare
  /// pc suffix collided on every loop iteration and retry attempt.
  int eventSeq = 0;

  /// Returns the next sequence value (post-incremented).
  int nextEventSeq() => eventSeq++;

  /// Resets to program-start conditions.
  void clear() {
    activeSessionId = null;
    activeModelDescriptor = null;
    activeModelFallbacks = const [];
    programToolSet = const [];
    errorHandlers.clear();
    eventSeq = 0;
  }

  @override
  String get stateKey => 'machineContext';

  @override
  Map<String, dynamic> captureState() => {
    if (activeSessionId != null) 'activeSessionId': activeSessionId,
    if (activeModelDescriptor != null) 'activeModelDescriptor': activeModelDescriptor!.toJson(),
    if (activeModelFallbacks.isNotEmpty)
      'activeModelFallbacks': [for (final f in activeModelFallbacks) f.toJson()],
    if (programToolSet.isNotEmpty) 'programToolSet': [for (final t in programToolSet) t.toJson()],
    if (errorHandlers.isNotEmpty) 'errorHandlers': [for (final h in errorHandlers) h.toJson()],
    if (eventSeq != 0) 'eventSeq': eventSeq,
  };

  @override
  void restoreState(Map<String, dynamic> snapshot) {
    activeSessionId = snapshot['activeSessionId'] as String?;
    final descriptor = snapshot['activeModelDescriptor'];
    activeModelDescriptor = descriptor == null
        ? null
        : ModelDescriptor.fromJson(Map<String, dynamic>.from(descriptor as Map));
    activeModelFallbacks = [
      for (final f in snapshot['activeModelFallbacks'] as List? ?? const [])
        ModelDescriptor.fromJson(Map<String, dynamic>.from(f as Map)),
    ];
    programToolSet = [
      for (final t in snapshot['programToolSet'] as List? ?? const [])
        ToolDefinition.fromJson(Map<String, dynamic>.from(t as Map)),
    ];
    eventSeq = (snapshot['eventSeq'] as num?)?.toInt() ?? 0;
    errorHandlers
      ..clear()
      ..addAll([
        for (final h in snapshot['errorHandlers'] as List? ?? const [])
          ErrorHandlerFrame.fromJson(Map<String, dynamic>.from(h as Map)),
      ]);
  }
}
