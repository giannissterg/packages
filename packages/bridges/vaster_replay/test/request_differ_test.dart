import 'package:test/test.dart';
import 'package:vaster_model/vaster_model.dart';
import 'package:vaster_replay/vaster_replay.dart';

/// The differ under crafted divergences — every delta shape located and
/// rendered, the v1 and order-divergence limitations named explicitly.
void main() {
  const differ = RequestDiffer();

  ModelTapeEntry entryFor(ModelRequest request) => ModelTapeEntry(
        fingerprint: ModelTape.fingerprintOf(request),
        requestPreview: 'p',
        recorded: FullRecordedRequest(request.toJson()),
        responseJson: ModelResponse(message: ChatMessage.model('r')).toJson(),
      );

  ModelRequest request({
    String system = 'You are a storyteller.',
    List<String> turns = const ['Story facts: Bo is a dog.', 'Continue.'],
    List<ContextCacheHint> hints = const [],
  }) =>
      ModelRequest(
        systemInstruction: ChatMessage.system(system),
        messages: [for (final t in turns) ChatMessage.user(t)],
        cacheHints: hints,
      );

  test('a mid-prompt edit is located to the character', () {
    final recorded = entryFor(request());
    final live = request(turns: ['Story facts: Bo is a CAT.', 'Continue.']);

    final report = differ.diff(live: live, candidate: recorded, callIndex: 2, candidateIndex: 2);

    final delta = report.deltas.whereType<MessageTextDelta>().single;
    expect(delta.index, 0);
    expect(delta.offset, 'Story facts: Bo is a '.length);
    expect(delta.liveExcerpt, contains('CAT'));
    expect(delta.recordedExcerpt, contains('dog'));
    expect(delta.affectsFingerprint, isTrue);
    expect(report.render(), contains('diverges at char ${delta.offset}'));
  });

  test('a grown prompt reports the length change and the tail offset', () {
    final recorded = entryFor(request());
    final live = request(turns: ['Story facts: Bo is a dog. Bo hates thunder.', 'Continue.']);
    final report = differ.diff(live: live, candidate: recorded, callIndex: 0, candidateIndex: 0);
    final delta = report.deltas.whereType<MessageTextDelta>().single;
    expect(delta.offset, 'Story facts: Bo is a dog.'.length,
        reason: 'a strict prefix diverges at the shorter length');
    expect(delta.liveLength - delta.recordedLength, greaterThan(0));
  });

  test('an inserted message reports count and cascades honestly', () {
    final recorded = entryFor(request());
    final live = request(turns: ['Story facts: Bo is a dog.', 'NEW instruction.', 'Continue.']);
    final report = differ.diff(live: live, candidate: recorded, callIndex: 1, candidateIndex: 1);
    expect(report.deltas.whereType<MessageCountDelta>().single.live, 3);
    // The shared-prefix walk still pinpoints where texts start disagreeing.
    expect(report.deltas.whereType<MessageTextDelta>(), isNotEmpty);
  });

  test('system-instruction drift is informational, never fingerprint-blamed', () {
    final recorded = entryFor(request());
    final live = request(system: 'You are a strict storyteller.');
    final report = differ.diff(live: live, candidate: recorded, callIndex: 0, candidateIndex: 0);
    final delta = report.deltas.whereType<SystemInstructionDelta>().single;
    expect(delta.affectsFingerprint, isFalse);
    expect(report.render(), contains('informational'));
    expect(report.deltas.where((d) => d.affectsFingerprint), isEmpty,
        reason: 'nothing fingerprint-relevant changed — and indeed this '
            'request would NOT have diverged in replay');
  });

  test('cache-hint drift is informational with fingerprints listed', () {
    final recorded =
        entryFor(request(hints: [const ContextCacheHint(regionId: 'r', contentFingerprint: 'aaa')]));
    final live = request(hints: [const ContextCacheHint(regionId: 'r', contentFingerprint: 'bbb')]);
    final report = differ.diff(live: live, candidate: recorded, callIndex: 0, candidateIndex: 0);
    final delta = report.deltas.whereType<CacheHintsDelta>().single;
    expect(delta.added, ['bbb']);
    expect(delta.removed, ['aaa']);
  });

  test('a v1 candidate names the limitation instead of guessing', () {
    const recorded = ModelTapeEntry(fingerprint: 'f', requestPreview: 'old preview', responseJson: {});
    final report = differ.diff(live: request(), candidate: recorded, callIndex: 0, candidateIndex: 0);
    expect(report.candidatePreviewOnly, isTrue);
    expect(report.render(), contains('v1 (preview only)'));
    expect(report.render(), contains('re-record'));
  });

  test('no candidate at this position → the tape is shorter than the run', () {
    final report = differ.diff(live: request(), candidate: null, callIndex: 4, candidateIndex: null);
    expect(report.render(), contains('more model calls than the tape holds'));
  });

  test('identical content against the candidate → order divergence named', () {
    final recorded = entryFor(request());
    final report = differ.diff(live: request(), candidate: recorded, callIndex: 0, candidateIndex: 0);
    expect(report.deltas, isEmpty);
    expect(report.render(), contains('call ORDER'));
  });

  test('newlines are visible in excerpts', () {
    final recorded = entryFor(request(turns: ['line one\nline two']));
    final live = request(turns: ['line one\nline 2wo']);
    final report = differ.diff(live: live, candidate: recorded, callIndex: 0, candidateIndex: 0);
    final delta = report.deltas.whereType<MessageTextDelta>().single;
    expect(delta.liveExcerpt, contains('⏎'));
  });
}
