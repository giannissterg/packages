import 'dart:convert';

import 'execution_step_frame.dart';
import 'model_tape.dart';

/// A parsed replay envelope — the VALUE (spec:
/// `docs/specs/REPLAY_ENVELOPE.md`): version, the embedded program (raw
/// JSON — the program schema is `vaster_instruction`'s, not this
/// package's, so consumers hydrate it), the step journal, and the model
/// tape.
final class ReplayEnvelope {
  final int version;

  /// `VasterProgram.toJson()` when the envelope embeds its program;
  /// null on pre-v0.2.0 recordings (callers must supply the program).
  final Map<String, dynamic>? programJson;

  final VasterExecutionJournal journal;
  final ModelTape tape;

  const ReplayEnvelope({
    required this.version,
    required this.programJson,
    required this.journal,
    required this.tape,
  });
}

/// The envelope codec — **one owner of the envelope shape**, both
/// directions (`run --record`/`--replay`, `vaster replay`, the debugger,
/// and the calibration fitter all read through here; drift between
/// consumers is structurally impossible). Const-constructible per the
/// house parsing rule: logic in an external instance class, testable in
/// isolation.
final class ReplayEnvelopeCodec {
  const ReplayEnvelopeCodec();

  /// Envelope format version written by this implementation (spec v2).
  static const int formatVersion = 2;

  ReplayEnvelope decode(Map<String, dynamic> map) {
    final version = map['version'] as int? ?? 1;
    if (version > formatVersion) {
      throw StateError('envelope version $version is newer than this '
          'reader (v$formatVersion) — refusing a partial read (spec '
          '§Migration guarantees).');
    }
    return ReplayEnvelope(
      version: version,
      programJson: map['program'] == null ? null : Map<String, dynamic>.from(map['program'] as Map),
      journal: VasterExecutionJournal.fromJson(
          Map<String, dynamic>.from(map['journal'] as Map? ?? {'frames': []})),
      tape: ModelTape.fromJson(Map<String, dynamic>.from(map['modelTape'] as Map? ?? {})),
    );
  }

  ReplayEnvelope decodeString(String json) => decode(jsonDecode(json) as Map<String, dynamic>);

  /// Encodes a complete v2 envelope (writers always write the current
  /// version).
  Map<String, dynamic> encode({
    required Map<String, dynamic> programJson,
    required Map<String, dynamic> journalJson,
    required ModelTape tape,
  }) =>
      {
        'version': formatVersion,
        'program': programJson,
        'journal': journalJson,
        'modelTape': tape.toJson(),
      };
}
