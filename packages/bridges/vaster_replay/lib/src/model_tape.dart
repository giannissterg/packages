import 'dart:convert';

import 'package:vaster_model/vaster_model.dart';

/// A recorded tape of model I/O — the deterministic-replay substrate.
///
/// [RecordingVasterModel] wraps a live backend and appends every
/// request/response pair; [ReplayVasterModel] answers later runs from the
/// tape with zero tokens and zero network. Matching is by request
/// *fingerprint* (a stable hash of the request's semantic content) with FIFO
/// order among identical fingerprints — robust to the arrival-order
/// nondeterminism of parallel dispatch while preserving iteration order for
/// repeated identical prompts.
///
/// This is "record in prod, replay in CI": a replayed run that makes exactly
/// the recorded model calls reproduces the original execution; a run whose
/// requests diverge fails fast with a [StateError] naming the unmatched
/// request — which IS the regression signal.
final class ModelTape {
  final List<ModelTapeEntry> entries;

  /// The recorded backend's identity and capabilities.
  ///
  /// Capabilities are part of the recording because they *shape the requests
  /// themselves*: a session sizes its context compilation from the model's
  /// context/output token limits, so replaying under different capabilities
  /// produces different messages — and therefore different fingerprints.
  /// A faithful replay presents what was recorded.
  String? recordedModelName;
  ModelCapabilities? recordedCapabilities;

  ModelTape({
    List<ModelTapeEntry>? entries,
    this.recordedModelName,
    this.recordedCapabilities,
  }) : entries = entries ?? [];

  int get length => entries.length;

  Map<String, dynamic> toJson() => {
        if (recordedModelName != null) 'recordedModelName': recordedModelName,
        if (recordedCapabilities != null)
          'recordedCapabilities': recordedCapabilities!.toJson(),
        'entries': [for (final e in entries) e.toJson()],
      };

  factory ModelTape.fromJson(Map<String, dynamic> json) => ModelTape(
        recordedModelName: json['recordedModelName'] as String?,
        recordedCapabilities: json['recordedCapabilities'] == null
            ? null
            : ModelCapabilities.fromJson(Map<String, dynamic>.from(
                json['recordedCapabilities'] as Map)),
        entries: [
          for (final raw in (json['entries'] as List? ?? []))
            ModelTapeEntry.fromJson(Map<String, dynamic>.from(raw as Map)),
        ],
      );

  /// Stable fingerprint of a request's semantic content: message roles and
  /// text, tool names, and the response schema. Deliberately excludes
  /// volatile details (usage hints, cache hints) so equivalent requests
  /// match across runs.
  static String fingerprintOf(ModelRequest request) {
    final canonical = jsonEncode({
      'messages': [
        for (final message in request.messages)
          {'role': message.role.name, 'text': message.text},
      ],
      'tools': [for (final tool in request.tools) tool.name],
      'schema': request.generationConfig.responseSchema,
    });
    // FNV-1a — dependency-free, stable across runs and platforms. Dart ints
    // are signed 64-bit and wrap on overflow, so the final value is masked to
    // 63 bits for a stable positive hex rendering.
    var hash = 0xcbf29ce484222325;
    for (final unit in canonical.codeUnits) {
      hash ^= unit;
      hash = hash * 0x100000001b3;
    }
    return (hash & 0x7FFFFFFFFFFFFFFF).toRadixString(16).padLeft(16, '0');
  }
}

/// One recorded request/response pair.
final class ModelTapeEntry {
  final String fingerprint;

  /// Human-readable request excerpt for divergence diagnostics.
  final String requestPreview;

  final Map<String, dynamic> responseJson;

  const ModelTapeEntry({
    required this.fingerprint,
    required this.requestPreview,
    required this.responseJson,
  });

  Map<String, dynamic> toJson() => {
        'fingerprint': fingerprint,
        'requestPreview': requestPreview,
        'response': responseJson,
      };

  factory ModelTapeEntry.fromJson(Map<String, dynamic> json) => ModelTapeEntry(
        fingerprint: json['fingerprint'] as String? ?? '',
        requestPreview: json['requestPreview'] as String? ?? '',
        responseJson:
            Map<String, dynamic>.from(json['response'] as Map? ?? {}),
      );
}

String _preview(ModelRequest request) {
  final text = request.messages.isEmpty ? '' : request.messages.last.text;
  final flat = text.replaceAll('\n', ' ');
  return flat.length <= 120 ? flat : '${flat.substring(0, 120)}…';
}

/// Wraps a live backend and records every generate() exchange onto [tape].
///
/// Streams delegate to the inner backend unrecorded (the ISA runtime never
/// streams; record/replay covers the generate path).
final class RecordingVasterModel implements VasterModel {
  final VasterModel inner;
  final ModelTape tape;

  RecordingVasterModel({required this.inner, required this.tape}) {
    // Stamp the backend's identity + capabilities: replay must present them
    // so requests are compiled identically.
    tape.recordedModelName = inner.modelName;
    tape.recordedCapabilities = inner.capabilities;
  }

  @override
  String get modelName => inner.modelName;

  @override
  ModelCapabilities get capabilities => inner.capabilities;

  @override
  Future<ModelResponse> generate(ModelRequest request) async {
    final response = await inner.generate(request);
    tape.entries.add(ModelTapeEntry(
      fingerprint: ModelTape.fingerprintOf(request),
      requestPreview: _preview(request),
      responseJson: response.toJson(),
    ));
    return response;
  }

  @override
  Stream<ModelResponseChunk> generateStream(ModelRequest request) =>
      inner.generateStream(request);
}

/// Answers generate() calls from a recorded [tape] — zero tokens, zero
/// network, perfectly reproducible.
final class ReplayVasterModel implements VasterModel {
  final ModelTape tape;
  final Set<int> _consumed = {};

  ReplayVasterModel({required this.tape});

  /// Entries not yet consumed by this replay (useful post-run: a fully
  /// faithful replay drains the tape).
  int get remaining => tape.entries.length - _consumed.length;

  @override
  String get modelName => 'replay:${tape.recordedModelName ?? 'tape'}';

  /// The recorded backend's capabilities — replaying under different limits
  /// would recompile contexts differently and diverge. Falls back to a
  /// conservative profile for tapes recorded before capabilities were
  /// captured.
  @override
  ModelCapabilities get capabilities =>
      tape.recordedCapabilities ??
      const ModelCapabilities(
        maxContextTokens: 128000,
        maxOutputTokens: 8192,
        supportsStreaming: true,
        supportsFunctionCalling: true,
        supportsVision: false,
        supportsSystemInstruction: true,
        supportsReasoning: false,
      );

  @override
  Future<ModelResponse> generate(ModelRequest request) async {
    final fingerprint = ModelTape.fingerprintOf(request);
    for (var i = 0; i < tape.entries.length; i++) {
      if (_consumed.contains(i)) continue;
      if (tape.entries[i].fingerprint == fingerprint) {
        _consumed.add(i);
        return ModelResponse.fromJson(tape.entries[i].responseJson);
      }
    }
    final unmatched = _preview(request);
    final pending = [
      for (var i = 0; i < tape.entries.length; i++)
        if (!_consumed.contains(i)) '  [$i] ${tape.entries[i].requestPreview}',
    ];
    throw StateError(
        'Replay diverged: no recorded response matches this request.\n'
        'Request: $unmatched\n'
        'Unconsumed tape entries (${pending.length}):\n${pending.join('\n')}');
  }

  @override
  Stream<ModelResponseChunk> generateStream(ModelRequest request) async* {
    final response = await generate(request);
    yield ModelResponseChunk(
      delta: TextPart(response.text),
      textDelta: response.text,
      finishReason: response.finishReason,
      usage: response.usage,
    );
  }
}
