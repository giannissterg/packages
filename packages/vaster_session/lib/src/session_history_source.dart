import 'dart:math' as math;

import 'package:vaster_context/vaster_context.dart';
import 'package:vaster_model/vaster_model.dart';
import 'package:vaster_token_estimate/vaster_token_estimate.dart';

/// Projects a session's live conversation history into context regions, so
/// history is budgeted, compressible, prioritized, and inspectable like every
/// other part of the context — instead of being concatenated unbudgeted after
/// the compiled context.
///
/// Chunking:
///  * **Closed chunks** — every full [messagesPerChunk] block becomes a region
///    with a *stable id and stable content* (`session:<sid>:history:<n>`), so
///    its fingerprint is stable: it can be summarized once and the compressed
///    shadow survives resyncs. Priority [closedChunkPriority], compressibility
///    `summarize`, utility decaying with age.
///  * **Open tail** — the most recent (< chunk size) turns stay verbatim:
///    `priority: high`, `compressibility: none`, rendered last.
///
/// Large `order` values guarantee history always renders after ambient
/// context regions, chronologically.
final class SessionHistorySource extends ConversationContextSource {
  final String sessionId;
  final List<ChatMessage> Function() historyProvider;
  final int messagesPerChunk;
  final ContextPriority closedChunkPriority;

  SessionHistorySource({
    required this.sessionId,
    required this.historyProvider,
    this.messagesPerChunk = 8,
    this.closedChunkPriority = ContextPriority.medium,
  }) : super(id: 'session:$sessionId:history', name: 'session_history');

  static int _estimate(Iterable<ChatMessage> messages) =>
      TokenEstimate.forMessages(messages);

  @override
  List<ContextRegion> getRegions() {
    final history = historyProvider();
    if (history.isEmpty) return const [];

    final regions = <ContextRegion>[];
    final fullChunks = history.length ~/ messagesPerChunk;

    for (var chunk = 0; chunk < fullChunks; chunk++) {
      final messages = history.sublist(
          chunk * messagesPerChunk, (chunk + 1) * messagesPerChunk);
      final ageInChunks = fullChunks - chunk; // 1 = newest closed chunk
      regions.add(ContextRegion(
        id: 'session:$sessionId:history:$chunk',
        label: 'history[$chunk] (${messages.length} turns)',
        messages: List<ChatMessage>.of(messages),
        estimatedTokens: _estimate(messages),
        classId: ContextClassTable.historyClassName,
        priority: closedChunkPriority,
        lifetime: ContextLifetime.session,
        compressibility: ContextCompressibility.summarize,
        utility: math.max(0.3, 1.0 - 0.1 * ageInChunks),
        order: 1000000 + chunk,
      ));
    }

    // The tail is ALWAYS emitted (even empty) so that when history crosses a
    // chunk boundary the stale tail content is replaced rather than lingering.
    final tail = history.sublist(fullChunks * messagesPerChunk);
    regions.add(ContextRegion(
      id: 'session:$sessionId:history:tail',
      label: 'history tail (${tail.length} recent turns)',
      messages: List<ChatMessage>.of(tail),
      estimatedTokens: _estimate(tail),
      classId: ContextClassTable.historyClassName,
      priority: ContextPriority.high,
      lifetime: ContextLifetime.session,
      compressibility: ContextCompressibility.none,
      order: 2000000,
    ));

    return regions;
  }
}
