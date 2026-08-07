/// The dedup window identity a tool call executes under — a value type,
/// not a raw string (Rule 11). The runtime derives one per agent dispatch
/// and threads it through task metadata (the serialized form is
/// [key]); [EffectRegion.none] means "no window: execute directly".
final class EffectRegion {
  /// Serialized region identity (opaque to tools and agents).
  final String key;

  const EffectRegion(this.key);

  const EffectRegion.none() : key = '';

  /// The runtime ISA tool loop's own dedup region (A6 unification: the
  /// ISA loop and agent loops share ONE key grammar through this
  /// contract — the ISA loop is just another region).
  const EffectRegion.isaLoop() : key = 'isa';

  /// The task-metadata slot the serialized region travels in — an ABI
  /// convention shared by the dispatching runtime and the agent.
  static const String metadataKey = 'effectRegion';

  /// Reads a region from task metadata; absent or empty means none.
  factory EffectRegion.fromMetadata(Map<String, dynamic> metadata) =>
      EffectRegion(metadata[metadataKey]?.toString() ?? '');

  bool get isActive => key.isNotEmpty;

  @override
  bool operator ==(Object other) =>
      other is EffectRegion && other.key == key;

  @override
  int get hashCode => key.hashCode;

  @override
  String toString() => isActive ? 'EffectRegion($key)' : 'EffectRegion.none';
}

/// What claiming an occurrence slot yielded — sealed, carrying its data
/// (Rule 2/11): exhaustive switches make the replay path impossible to
/// ignore.
sealed class ToolEffectClaim {
  const ToolEffectClaim();
}

/// This occurrence already executed: [result] is the recorded payload to
/// hand back WITHOUT re-executing the side effect.
final class ToolEffectReplay extends ToolEffectClaim {
  final Map<String, dynamic> result;
  const ToolEffectReplay(this.result);
}

/// A fresh occurrence: execute the call, then [ToolEffectRecorder.commit]
/// the successful result into this slot. [token] is recorder-internal
/// slot identity — opaque to callers.
final class ToolEffectSlot extends ToolEffectClaim {
  final Object token;
  const ToolEffectSlot(this.token);
}

/// No dedup window is active (no region, or the recorder is a no-op):
/// execute directly, record nothing.
final class ToolEffectInert extends ToolEffectClaim {
  const ToolEffectInert();
}

/// Records tool-call effects so a retried attempt replays results instead
/// of re-performing side effects (GAP-3a — the agent-loop face of the
/// runtime's effect ledger). Pure tool domain: implementations map
/// (region, name, args, occurrence) to recorded JSON results; this
/// package knows nothing of ISA, runtimes, or agents (Rule 6.5).
abstract interface class ToolEffectRecorder {
  /// Claims the next occurrence slot for (region, name, arguments).
  /// [callId] is the model-assigned call identity, carried for
  /// observability (replay events) — never part of the dedup key.
  ToolEffectClaim claim({
    required EffectRegion region,
    required String name,
    required Map<String, dynamic> arguments,
    String? callId,
  });

  /// Records [result] into [slot] and echoes it back, so call sites
  /// compose (`replay.result` or `commit(slot, await execute())`) —
  /// operations return what they did (Rule 11). Commit only results
  /// that really performed and succeeded.
  Map<String, dynamic> commit(ToolEffectSlot slot, Map<String, dynamic> result);
}

/// The canonical default: never replays, never records (Rule 5 — a
/// required collaborator with a no-op canonical instance, not a null).
final class NoopToolEffectRecorder implements ToolEffectRecorder {
  const NoopToolEffectRecorder();

  @override
  ToolEffectClaim claim({
    required EffectRegion region,
    required String name,
    required Map<String, dynamic> arguments,
    String? callId,
  }) =>
      const ToolEffectInert();

  @override
  Map<String, dynamic> commit(
          ToolEffectSlot slot, Map<String, dynamic> result) =>
      result;
}

/// A stable indirection for wiring-order freedom: agents are often
/// created before the component that owns the real recorder exists (the
/// runtime's ledger is machine state and cannot live in the VM). Agents
/// hold this binding eagerly (Rule 5); the owner [bind]s the live
/// recorder once it exists. Last bind wins — one executing runtime per
/// VM is the supported shape.
final class ToolEffectRecorderBinding implements ToolEffectRecorder {
  ToolEffectRecorder _bound;

  ToolEffectRecorderBinding([this._bound = const NoopToolEffectRecorder()]);

  /// Binds [recorder] and returns the recorder it displaced (Rule 11 —
  /// the displaced binding is the operation's meaningful result).
  ToolEffectRecorder bind(ToolEffectRecorder recorder) {
    final previous = _bound;
    _bound = recorder;
    return previous;
  }

  @override
  ToolEffectClaim claim({
    required EffectRegion region,
    required String name,
    required Map<String, dynamic> arguments,
    String? callId,
  }) =>
      _bound.claim(
          region: region, name: name, arguments: arguments, callId: callId);

  @override
  Map<String, dynamic> commit(
          ToolEffectSlot slot, Map<String, dynamic> result) =>
      _bound.commit(slot, result);
}
