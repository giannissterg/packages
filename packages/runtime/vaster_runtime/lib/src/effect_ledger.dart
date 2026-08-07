import 'dart:convert';

import 'package:vaster_machine_state/vaster_machine_state.dart';

/// One open effect scope: the `PushEffectScopeOp` pc that opened it (region
/// identity) and the per-key occurrence cursors of the CURRENT attempt.
/// Cursors are attempt-transient (reset by `MarkEffectRetryOp`); records
/// live in the ledger's store so they outlive the frame (rules.md Rule 2:
/// one entry object per scope, no parallel bookkeeping maps).
final class _EffectScopeFrame {
  final int pushPc;
  final Map<String, int> cursors;

  _EffectScopeFrame({required this.pushPc, Map<String, int>? cursors})
      : cursors = cursors ?? {};

  Map<String, dynamic> toJson() => {
        'pushPc': pushPc,
        if (cursors.isNotEmpty) 'cursors': cursors,
      };

  factory _EffectScopeFrame.fromJson(Map<String, dynamic> json) =>
      _EffectScopeFrame(
        pushPc: (json['pushPc'] as num).toInt(),
        cursors: Map<String, int>.from(json['cursors'] as Map? ?? {}),
      );
}

/// One claimed occurrence slot (see [EffectLedger.claim]): either a
/// [recorded] result to replay, or the slot identity a successful result
/// commits into. Inert outside any scope (both null → commit no-ops).
final class EffectClaim {
  /// The recorded result to replay, when this occurrence already executed.
  final Map<String, dynamic>? recorded;

  final String? _recordKey;

  const EffectClaim._(this.recorded, this._recordKey);

  /// The claimed slot's stable identity, null when inert. This is the
  /// dispatch-visible handle: GAP-3a threads it to agents as their
  /// [EffectRegion] so agent-internal tool records nest under the
  /// dispatch that owns them.
  String? get slotId => _recordKey;
}

/// The idempotency ledger (REL-P4): inside an effect scope, non-compensable
/// tool calls record their results; a retry attempt REPLAYS a recorded
/// result instead of re-executing the side effect. Compensable effects
/// (transactional VFS) never pass through here — rollback is their undo.
///
/// **Identity**: a call is identified by its scope's region path (the pcs
/// of every open `PushEffectScopeOp`, outermost first), the tool name, the
/// canonical JSON of its arguments, and its occurrence index within the
/// current attempt. Region paths make nesting compose: when an outer retry
/// re-enters an inner `Resilient`, the inner scope re-opens at the same pc,
/// so its calls find the records the previous incarnation wrote.
///
/// **Lifecycle**: `MarkEffectRetryOp` (compiled into `Resilient`'s catch)
/// resets the innermost frame's cursors so the next attempt matches
/// occurrences from 1 again. Popping an inner scope keeps its records (an
/// outer retry must still remember what executed); popping the OUTERMOST
/// scope clears the store — the retry region completed, its history is
/// dead. Error unwinding closes scopes abandoned by a failure the same
/// way ([unwindTo]).
///
/// Machine state (rules.md Rule 8): frames and records serialize; a
/// checkpoint taken mid-retry resumes with its dedup memory intact.
final class EffectLedger implements MachineStateComponent {
  final List<_EffectScopeFrame> _frames = [];
  final Map<String, Map<String, dynamic>> _records = {};

  /// Number of open scopes — captured into `ErrorHandlerFrame` at handler
  /// push, the unwind target when a failure is caught.
  int get depth => _frames.length;

  bool get inScope => _frames.isNotEmpty;

  void pushScope(int pc) => _frames.add(_EffectScopeFrame(pushPc: pc));

  /// Closes the innermost scope. Records are retained while any enclosing
  /// scope remains open; closing the outermost scope drops the store.
  void popScope() {
    if (_frames.isEmpty) return;
    _frames.removeLast();
    if (_frames.isEmpty) _records.clear();
  }

  /// Retry boundary of the innermost scope: the next attempt's calls count
  /// occurrences from 1 again, lining up with the recorded ones.
  void markRetry() {
    if (_frames.isEmpty) return;
    _frames.last.cursors.clear();
  }

  /// Closes every scope above [targetDepth] — the error-unwinding path for
  /// scopes a failure abandoned mid-region.
  void unwindTo(int targetDepth) {
    while (_frames.length > targetDepth) {
      popScope();
    }
  }

  /// Claims the next occurrence slot for (name, args) in the current
  /// scope. The returned claim either carries a [EffectClaim.recorded]
  /// result to replay, or names the slot a successful result [commit]s
  /// into. Outside any scope the claim is inert (no replay, commit is a
  /// no-op) — zero bookkeeping, zero overhead.
  ///
  /// This is the primitive batch consumers need (parallel dispatch claims
  /// every entry in declaration order BEFORE fanning out); sequential
  /// callers use [executeOrReplay].
  EffectClaim claim({
    required String name,
    required Map<String, dynamic> arguments,
  }) {
    if (_frames.isEmpty) return const EffectClaim._(null, null);
    final frame = _frames.last;
    final callKey = '$name|${_canonical(arguments)}';
    final occurrence = (frame.cursors[callKey] ?? 0) + 1;
    frame.cursors[callKey] = occurrence;
    final regionPath = _frames.map((f) => f.pushPc).join('/');
    final recordKey = '$regionPath|$callKey|$occurrence';
    final recorded = _records[recordKey];
    return EffectClaim._(
        recorded == null ? null : Map<String, dynamic>.from(recorded),
        recordKey);
  }

  /// Records [result] into [claim]'s slot and echoes it back so call
  /// sites compose (Rule 11). Call only for effects that really
  /// performed and succeeded — failures must re-execute on retry.
  Map<String, dynamic> commit(EffectClaim claim, Map<String, dynamic> result) {
    final key = claim._recordKey;
    if (key != null) _records[key] = Map<String, dynamic>.from(result);
    return result;
  }

  /// Executes [execute] exactly once per (region, name, args, occurrence):
  /// a recorded result replays without re-executing. Sugar over
  /// [claim]/[commit] for sequential callers.
  ///
  /// Only successful results are recorded: an errored result re-executes
  /// on retry (the failed call most plausibly did not perform its effect,
  /// and healing is what the retry is for).
  Future<({Map<String, dynamic> result, bool replayed})> executeOrReplay({
    required String name,
    required Map<String, dynamic> arguments,
    required Future<Map<String, dynamic>> Function() execute,
  }) async {
    final slot = claim(name: name, arguments: arguments);
    final recorded = slot.recorded;
    if (recorded != null) return (result: recorded, replayed: true);
    final result = await execute();
    if (!result.containsKey('error')) commit(slot, result);
    return (result: result, replayed: false);
  }

  /// Resets to program-start conditions.
  void clear() {
    _frames.clear();
    _records.clear();
  }

  @override
  String get stateKey => 'effectLedger';

  @override
  Map<String, dynamic> captureState() => {
        if (_frames.isNotEmpty)
          'frames': [for (final f in _frames) f.toJson()],
        if (_records.isNotEmpty) 'records': _records,
      };

  @override
  void restoreState(Map<String, dynamic> snapshot) {
    _frames
      ..clear()
      ..addAll([
        for (final f in snapshot['frames'] as List? ?? const [])
          _EffectScopeFrame.fromJson(Map<String, dynamic>.from(f as Map)),
      ]);
    _records.clear();
    (snapshot['records'] as Map? ?? const {}).forEach((key, value) {
      _records['$key'] = Map<String, dynamic>.from(value as Map);
    });
  }

  /// Canonical JSON: map keys sorted recursively, so argument maps that
  /// differ only in key order produce the same call identity.
  static String _canonical(Object? value) => jsonEncode(_normalize(value));

  static Object? _normalize(Object? value) {
    if (value is Map) {
      final entries = value.entries
          .map((e) => MapEntry('${e.key}', _normalize(e.value)))
          .toList()
        ..sort((a, b) => a.key.compareTo(b.key));
      return {for (final e in entries) e.key: e.value};
    }
    if (value is List) return [for (final item in value) _normalize(item)];
    return value;
  }
}
