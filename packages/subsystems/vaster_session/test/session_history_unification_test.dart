import 'package:test/test.dart';
import 'package:vaster_context/vaster_context.dart';
import 'package:vaster_context_manager/vaster_context_manager.dart';
import 'package:vaster_model/vaster_model.dart';
import 'package:vaster_model_fake/vaster_model_fake.dart';
import 'package:vaster_session/vaster_session.dart';

void main() {
  group('SessionHistorySource projection', () {
    test('chunks + tail with stable ids, priorities, and order', () {
      final history = [
        for (var i = 0; i < 19; i++)
          i.isEven ? ChatMessage.user('turn $i') : ChatMessage.model('turn $i'),
      ];
      final source = SessionHistorySource(
        sessionId: 's1',
        historyProvider: () => history,
      );

      final regions = source.getRegions();
      // 19 messages / 8 per chunk = 2 closed chunks + tail(3).
      expect(regions, hasLength(3));
      expect(regions[0].id, equals('session:s1:history:0'));
      expect(regions[1].id, equals('session:s1:history:1'));
      expect(regions[2].id, equals('session:s1:history:tail'));

      expect(regions[0].compressibility, equals(ContextCompressibility.summarize));
      expect(regions[2].compressibility, equals(ContextCompressibility.none));
      expect(regions[2].priority, equals(ContextPriority.high));
      expect(regions[0].order, lessThan(regions[1].order));
      expect(regions[1].order, lessThan(regions[2].order));
      // Older chunk has lower utility.
      expect(regions[0].utility, lessThan(regions[1].utility));
      expect(regions[2].messages, hasLength(3));
    });

    test('empty history projects nothing', () {
      final source =
          SessionHistorySource(sessionId: 's1', historyProvider: () => []);
      expect(source.getRegions(), isEmpty);
    });
  });

  group('BasicModelSession — unified history', () {
    test('request contains each history message exactly once, in order',
        () async {
      final fakeModel = FakeVasterModel();
      final session = BasicModelSession(
        sessionId: 'chat',
        model: fakeModel,
        contextManager: BasicContextManager(),
      );

      await session.send(ChatMessage.user('first question'));
      await session.send(ChatMessage.user('second question'));

      final request = fakeModel.recordedRequests.last;
      final texts = request.messages.map((m) => m.text).toList();

      // Chronology preserved; no duplicates.
      expect(texts.where((t) => t == 'first question'), hasLength(1));
      expect(texts.where((t) => t == 'second question'), hasLength(1));
      expect(texts.indexOf('first question'), lessThan(texts.indexOf('second question')));
      // The live user turn is the LAST message (arrives via the tail region).
      expect(texts.last, equals('second question'));
    });

    test('ambient heap regions render before history', () async {
      final fakeModel = FakeVasterModel();
      final manager = BasicContextManager();
      final session = BasicModelSession(
        sessionId: 'chat',
        model: fakeModel,
        contextManager: manager,
      );
      manager.addRegion(ContextRegion.text(
        id: 'ambient_doc',
        label: 'doc',
        role: Role.user,
        text: 'AMBIENT DOCUMENT CONTENT',
      ));

      await session.send(ChatMessage.user('question about the doc'));

      final texts =
          fakeModel.recordedRequests.last.messages.map((m) => m.text).toList();
      expect(texts.indexWhere((t) => t.contains('AMBIENT DOCUMENT')),
          lessThan(texts.indexOf('question about the doc')));
    });

    test('compressed history chunk survives subsequent sends (shadowing)',
        () async {
      final fakeModel = FakeVasterModel();
      final manager = BasicContextManager(
        compressors: [const TruncatingCompressor(keepTailMessages: 1)],
      );
      final session = BasicModelSession(
        sessionId: 'long',
        model: fakeModel,
        contextManager: manager,
      );

      // Build up enough history to close a chunk (8+ messages: 4 sends = 8).
      for (var i = 0; i < 5; i++) {
        await session.send(ChatMessage.user('question $i ${'padding ' * 30}'));
      }
      expect(manager.getRegion('session:long:history:0'), isNotNull);

      // Compress the closed chunk explicitly.
      await manager.compact(
          targetTokens: 20, regionId: 'session:long:history:0');
      expect(manager.getRegion('session:long:history:0')!.isCompressed, isTrue);

      // Another send re-syncs sources — the compressed shadow must survive
      // because the underlying chunk content is unchanged.
      await session.send(ChatMessage.user('one more question'));
      expect(manager.getRegion('session:long:history:0')!.isCompressed, isTrue,
          reason: 'stable chunk content => shadow survives resync');

      // And the compiled request contains the truncation marker, not the
      // original chunk messages.
      final texts =
          fakeModel.recordedRequests.last.messages.map((m) => m.text).toList();
      expect(texts.any((t) => t.contains('[context truncated')), isTrue);
    });

    test('clearHistory removes projected regions', () async {
      final fakeModel = FakeVasterModel();
      final manager = BasicContextManager();
      final session = BasicModelSession(
        sessionId: 'wipe',
        model: fakeModel,
        contextManager: manager,
      );
      await session.send(ChatMessage.user('hello'));
      expect(
          manager.regions.where((r) => r.id.startsWith('session:wipe:history')),
          isNotEmpty);

      session.clearHistory();
      expect(session.history, isEmpty);
      expect(
          manager.regions.where((r) => r.id.startsWith('session:wipe:history')),
          isEmpty);
    });

    test('ephemeral-lifetime scratch regions are pruned at turn end', () async {
      final fakeModel = FakeVasterModel();
      final manager = BasicContextManager();
      final session = BasicModelSession(
        sessionId: 'scratch',
        model: fakeModel,
        contextManager: manager,
      );
      manager.addRegion(ContextRegion.text(
        id: 'scratchpad',
        label: 'scratch',
        role: Role.user,
        text: 'transient note',
        lifetime: ContextLifetime.ephemeral,
      ));

      await session.send(ChatMessage.user('go'));
      expect(manager.getRegion('scratchpad'), isNull,
          reason: 'turn boundary expires ephemeral regions');
    });
  });
}
