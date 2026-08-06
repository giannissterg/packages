import 'dart:convert';

import 'package:vaster_model/vaster_model.dart';

import 'model_tape.dart';

/// One located difference between a live request and a recorded one —
/// sealed, so renderers and tests handle every shape exhaustively.
sealed class RequestDelta {
  const RequestDelta();

  /// Whether this delta participates in the replay fingerprint (messages,
  /// tools, schema) — informational deltas (system instruction, cache
  /// hints) explain context drift but cannot themselves have caused the
  /// divergence.
  bool get affectsFingerprint;

  String describe();
}

final class MessageCountDelta extends RequestDelta {
  final int live;
  final int recorded;
  const MessageCountDelta({required this.live, required this.recorded});
  @override
  bool get affectsFingerprint => true;
  @override
  String describe() => 'message count: $live live vs $recorded recorded '
      '(${live > recorded ? '+' : ''}${live - recorded})';
}

final class MessageRoleDelta extends RequestDelta {
  final int index;
  final String live;
  final String recorded;
  const MessageRoleDelta(
      {required this.index, required this.live, required this.recorded});
  @override
  bool get affectsFingerprint => true;
  @override
  String describe() =>
      'message[$index] role: $live live vs $recorded recorded';
}

final class MessageTextDelta extends RequestDelta {
  final int index;
  final String role;

  /// First differing character offset.
  final int offset;
  final String liveExcerpt;
  final String recordedExcerpt;
  final int liveLength;
  final int recordedLength;

  const MessageTextDelta({
    required this.index,
    required this.role,
    required this.offset,
    required this.liveExcerpt,
    required this.recordedExcerpt,
    required this.liveLength,
    required this.recordedLength,
  });
  @override
  bool get affectsFingerprint => true;
  @override
  String describe() => 'message[$index] ($role) text diverges at char '
      '$offset (${liveLength - recordedLength >= 0 ? '+' : ''}'
      '${liveLength - recordedLength} chars): '
      '"$recordedExcerpt" → "$liveExcerpt"';
}

final class ToolsDelta extends RequestDelta {
  final List<String> added;
  final List<String> removed;
  const ToolsDelta({required this.added, required this.removed});
  @override
  bool get affectsFingerprint => true;
  @override
  String describe() => 'tools: '
      '${added.isNotEmpty ? '+${added.join(',')}' : ''}'
      '${added.isNotEmpty && removed.isNotEmpty ? ' ' : ''}'
      '${removed.isNotEmpty ? '-${removed.join(',')}' : ''}';
}

final class SchemaDelta extends RequestDelta {
  final bool liveHas;
  final bool recordedHas;
  const SchemaDelta({required this.liveHas, required this.recordedHas});
  @override
  bool get affectsFingerprint => true;
  @override
  String describe() => 'response schema: '
      '${liveHas ? (recordedHas ? 'changed' : 'added') : 'removed'}';
}

final class SystemInstructionDelta extends RequestDelta {
  final int offset;
  final String liveExcerpt;
  final String recordedExcerpt;
  const SystemInstructionDelta(
      {required this.offset,
      required this.liveExcerpt,
      required this.recordedExcerpt});
  @override
  bool get affectsFingerprint => false;
  @override
  String describe() => 'system instruction diverges at char $offset '
      '(informational — not part of the fingerprint): '
      '"$recordedExcerpt" → "$liveExcerpt"';
}

final class CacheHintsDelta extends RequestDelta {
  final List<String> added;
  final List<String> removed;
  const CacheHintsDelta({required this.added, required this.removed});
  @override
  bool get affectsFingerprint => false;
  @override
  String describe() => 'cache hints (informational): '
      '${added.isNotEmpty ? '+${added.length}' : ''}'
      '${removed.isNotEmpty ? ' -${removed.length}' : ''} '
      '(fingerprints ${[...added, ...removed].join(', ')})';
}

/// The structured answer to "what changed?" for one diverged call.
final class DivergenceReport {
  final int callIndex;

  /// Tape index of the positional candidate compared against, or null
  /// when the tape had no entry at this position.
  final int? candidateIndex;

  /// True when the candidate is a v1 preview-only recording — the
  /// limitation is named instead of guessed around (spec reader rule).
  final bool candidatePreviewOnly;

  final List<RequestDelta> deltas;

  const DivergenceReport({
    required this.callIndex,
    required this.candidateIndex,
    required this.candidatePreviewOnly,
    required this.deltas,
  });

  String render() {
    final buffer = StringBuffer();
    buffer.writeln('call #$callIndex diverged'
        '${candidateIndex != null ? ' (vs recording [$candidateIndex])' : ''}:');
    if (candidateIndex == null) {
      buffer.writeln('  no recording at this position — the live run makes '
          'more model calls than the tape holds.');
      return buffer.toString();
    }
    if (candidatePreviewOnly) {
      buffer.writeln('  recording is v1 (preview only) — re-record to get '
          'message-level diffs. Recorded preview is shown in the '
          'divergence error.');
      return buffer.toString();
    }
    if (deltas.isEmpty) {
      buffer.writeln('  no content difference found against the positional '
          'candidate — the divergence is in call ORDER (an earlier call '
          'consumed this recording, or calls arrived reordered).');
      return buffer.toString();
    }
    for (final delta in deltas) {
      buffer.writeln(
          '  ${delta.affectsFingerprint ? '✗' : 'ℹ'} ${delta.describe()}');
    }
    return buffer.toString();
  }
}

/// Computes [DivergenceReport]s — pure logic over values, no I/O.
/// Positional comparison by design: "call N changed" is the story a
/// regression report tells (fingerprint-FIFO remains the *matching*
/// rule; this class only ever runs after a mismatch).
final class RequestDiffer {
  /// Characters of context on each side of a divergence offset.
  final int excerptContext;

  const RequestDiffer({this.excerptContext = 24});

  DivergenceReport diff({
    required ModelRequest live,
    required ModelTapeEntry? candidate,
    required int callIndex,
    required int? candidateIndex,
  }) {
    if (candidate == null) {
      return DivergenceReport(
          callIndex: callIndex,
          candidateIndex: null,
          candidatePreviewOnly: false,
          deltas: const []);
    }
    final recorded = switch (candidate.recorded) {
      FullRecordedRequest(:final requestJson) =>
        ModelRequest.fromJson(requestJson),
      PreviewOnlyRequest() => null,
    };
    if (recorded == null) {
      return DivergenceReport(
          callIndex: callIndex,
          candidateIndex: candidateIndex,
          candidatePreviewOnly: true,
          deltas: const []);
    }

    final deltas = <RequestDelta>[];

    if (live.messages.length != recorded.messages.length) {
      deltas.add(MessageCountDelta(
          live: live.messages.length, recorded: recorded.messages.length));
    }
    final shared = live.messages.length < recorded.messages.length
        ? live.messages.length
        : recorded.messages.length;
    for (var i = 0; i < shared; i++) {
      final liveMessage = live.messages[i];
      final recordedMessage = recorded.messages[i];
      if (liveMessage.role.name != recordedMessage.role.name) {
        deltas.add(MessageRoleDelta(
            index: i,
            live: liveMessage.role.name,
            recorded: recordedMessage.role.name));
      }
      final offset = _firstDifference(liveMessage.text, recordedMessage.text);
      if (offset != -1) {
        deltas.add(MessageTextDelta(
          index: i,
          role: liveMessage.role.name,
          offset: offset,
          liveExcerpt: _excerpt(liveMessage.text, offset),
          recordedExcerpt: _excerpt(recordedMessage.text, offset),
          liveLength: liveMessage.text.length,
          recordedLength: recordedMessage.text.length,
        ));
      }
    }

    final liveTools = live.tools.map((t) => t.name).toSet();
    final recordedTools = recorded.tools.map((t) => t.name).toSet();
    if (liveTools.length != recordedTools.length ||
        !liveTools.containsAll(recordedTools)) {
      deltas.add(ToolsDelta(
        added: (liveTools.difference(recordedTools)).toList()..sort(),
        removed: (recordedTools.difference(liveTools)).toList()..sort(),
      ));
    }

    final liveSchema = live.generationConfig.responseSchema;
    final recordedSchema = recorded.generationConfig.responseSchema;
    if (jsonEncode(liveSchema) != jsonEncode(recordedSchema)) {
      deltas.add(SchemaDelta(
          liveHas: liveSchema != null, recordedHas: recordedSchema != null));
    }

    final liveSystem = live.systemInstruction?.text ?? '';
    final recordedSystem = recorded.systemInstruction?.text ?? '';
    final systemOffset = _firstDifference(liveSystem, recordedSystem);
    if (systemOffset != -1) {
      deltas.add(SystemInstructionDelta(
        offset: systemOffset,
        liveExcerpt: _excerpt(liveSystem, systemOffset),
        recordedExcerpt: _excerpt(recordedSystem, systemOffset),
      ));
    }

    final liveHints = live.cacheHints.map((h) => h.contentFingerprint).toSet();
    final recordedHints =
        recorded.cacheHints.map((h) => h.contentFingerprint).toSet();
    if (liveHints.length != recordedHints.length ||
        !liveHints.containsAll(recordedHints)) {
      deltas.add(CacheHintsDelta(
        added: (liveHints.difference(recordedHints)).toList()..sort(),
        removed: (recordedHints.difference(liveHints)).toList()..sort(),
      ));
    }

    return DivergenceReport(
      callIndex: callIndex,
      candidateIndex: candidateIndex,
      candidatePreviewOnly: false,
      deltas: deltas,
    );
  }

  /// First index at which [a] and [b] differ, or -1 when equal (a strict
  /// prefix differs at the shorter length).
  static int _firstDifference(String a, String b) {
    final shared = a.length < b.length ? a.length : b.length;
    for (var i = 0; i < shared; i++) {
      if (a.codeUnitAt(i) != b.codeUnitAt(i)) return i;
    }
    return a.length == b.length ? -1 : shared;
  }

  String _excerpt(String text, int offset) {
    final start = offset - excerptContext < 0 ? 0 : offset - excerptContext;
    final end = offset + excerptContext > text.length
        ? text.length
        : offset + excerptContext;
    final head = start > 0 ? '…' : '';
    final tail = end < text.length ? '…' : '';
    return '$head${text.substring(start, end).replaceAll('\n', '⏎')}$tail';
  }
}
