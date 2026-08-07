import 'package:vaster_runtime/vaster_runtime.dart';

/// Conformance class of a vector: `core` vectors are mandatory for every
/// conforming runtime; `capability` vectors apply only when the host
/// implements the named capability.
enum ConformanceClass { core, capability }

/// The declared result value of a halted vector, wrapped so an expected
/// `null` is expressible (field absence means "no result expectation").
final class ResultExpectation {
  final Object? value;

  const ResultExpectation({required this.value});
}

/// What a conforming runtime must observe at the end of a vector run.
final class ConformanceExpectation {
  /// Exact `RuntimeStatus` name; only `halted`, `pausedForHuman`, and
  /// `error` are legal in vectors (`timedOut` is wall-clock-dependent).
  final RuntimeStatus finalStatus;

  /// Total executed steps — must equal the journal's frame count too
  /// (truncation guard).
  final int steps;

  /// Expected value of the program's `resultBinding` register (halted
  /// vectors only).
  final ResultExpectation? result;

  /// PC of the trapping instruction (required when [finalStatus] is
  /// `error`; `errorDetails` prose is out of contract).
  final int? trapPc;

  /// Subset-matched fields of the pending human-interaction request
  /// (pausedForHuman vectors only).
  final Map<String, dynamic>? pendingRequest;

  /// Expected memory-mount exports: mountPrefix → (path → base64).
  final Map<String, Map<String, String>>? vfs;

  const ConformanceExpectation({
    required this.finalStatus,
    required this.steps,
    this.result,
    this.trapPc,
    this.pendingRequest,
    this.vfs,
  });
}

/// One conformance vector: a named replay envelope plus the expectations a
/// conforming runtime must reproduce (spec: docs/specs/ISA.md §Conformance
/// procedure).
final class ConformanceVector {
  static const int currentVersion = 1;

  final int conformanceVersion;
  final String name;
  final String description;
  final ConformanceClass conformanceClass;

  /// Opcode-family tag (`registers`, `control`, `model`, `vfs`, …).
  final String family;

  /// Host capability this vector requires; non-null iff
  /// [conformanceClass] is [ConformanceClass.capability].
  final String? capability;

  /// Envelope file, relative to the manifest's directory.
  final String envelopePath;

  final ConformanceExpectation expect;

  const ConformanceVector({
    this.conformanceVersion = currentVersion,
    required this.name,
    required this.description,
    required this.conformanceClass,
    required this.family,
    this.capability,
    required this.envelopePath,
    required this.expect,
  }) : assert(
         (conformanceClass == ConformanceClass.capability) == (capability != null),
         'capability is required exactly for capability-class vectors',
       );
}

/// The manifest codec — one owner of the `.vector.json` shape, both
/// directions (const-constructible per the house parsing rule).
final class ConformanceVectorCodec {
  const ConformanceVectorCodec();

  ConformanceVector decode(Map<String, dynamic> json) {
    final version = json['conformanceVersion'] as int? ?? 1;
    if (version > ConformanceVector.currentVersion) {
      throw StateError(
        'conformance vector version $version is newer than this reader '
        '(v${ConformanceVector.currentVersion}) — refusing a partial read.',
      );
    }
    final expectJson = Map<String, dynamic>.from(json['expect'] as Map);
    return ConformanceVector(
      conformanceVersion: version,
      name: json['name'] as String,
      description: json['description'] as String? ?? '',
      conformanceClass: ConformanceClass.values.byName(json['class'] as String),
      family: json['family'] as String,
      capability: json['capability'] as String?,
      envelopePath: json['envelope'] as String,
      expect: ConformanceExpectation(
        finalStatus: RuntimeStatus.values.byName(expectJson['finalStatus'] as String),
        steps: expectJson['steps'] as int,
        result: expectJson.containsKey('result')
            ? ResultExpectation(value: (expectJson['result'] as Map)['value'])
            : null,
        trapPc: expectJson['trapPc'] as int?,
        pendingRequest: expectJson['pendingRequest'] == null
            ? null
            : Map<String, dynamic>.from(expectJson['pendingRequest'] as Map),
        vfs: expectJson['vfs'] == null
            ? null
            : {
                for (final mount in (expectJson['vfs'] as Map).entries)
                  mount.key.toString(): {
                    for (final f in (mount.value as Map).entries) f.key.toString(): f.value.toString(),
                  },
              },
      ),
    );
  }

  Map<String, dynamic> encode(ConformanceVector vector) => {
    'conformanceVersion': vector.conformanceVersion,
    'name': vector.name,
    'description': vector.description,
    'class': vector.conformanceClass.name,
    'family': vector.family,
    if (vector.capability != null) 'capability': vector.capability,
    'envelope': vector.envelopePath,
    'expect': {
      'finalStatus': vector.expect.finalStatus.name,
      'steps': vector.expect.steps,
      if (vector.expect.result != null) 'result': {'value': vector.expect.result!.value},
      if (vector.expect.trapPc != null) 'trapPc': vector.expect.trapPc,
      if (vector.expect.pendingRequest != null) 'pendingRequest': vector.expect.pendingRequest,
      if (vector.expect.vfs != null) 'vfs': vector.expect.vfs,
    },
  };
}
