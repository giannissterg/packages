import 'package:vaster_context/vaster_context.dart';
import 'package:vaster_model/vaster_model.dart';

import 'context_compressor.dart';

/// Where truncation removes messages from.
enum TruncationMode {
  /// Keep head and tail, drop the middle (default — preserves opening context
  /// and recency).
  dropMiddle,

  /// Drop oldest messages first.
  dropOldest,
}

/// Deterministic, model-free compressor: drops whole messages and inserts a
/// single marker message describing what was omitted. Never empties a region.
final class TruncatingCompressor implements ContextCompressor {
  final TruncationMode mode;
  final int keepHeadMessages;
  final int keepTailMessages;

  const TruncatingCompressor({
    this.mode = TruncationMode.dropMiddle,
    this.keepHeadMessages = 1,
    this.keepTailMessages = 4,
  });

  @override
  String get id => 'truncating';

  @override
  ContextCompressibility get level => ContextCompressibility.truncate;

  static int _estimate(Iterable<ChatMessage> messages) =>
      messages.fold(0, (sum, m) => sum + (m.text.length / 4).ceil() + 4);

  @override
  Future<CompressionResult> compress(ContextRegion region, {required int targetTokens}) async {
    final messages = List<ChatMessage>.of(region.messages);
    final before = region.estimatedTokens;

    if (messages.length <= 1 || _estimate(messages) <= targetTokens) {
      return CompressionResult(region: region, tokensSaved: 0, lossy: false);
    }

    final head = mode == TruncationMode.dropMiddle
        ? messages.take(keepHeadMessages).toList()
        : <ChatMessage>[];
    final tail = <ChatMessage>[];
    final droppable = messages.sublist(head.length, messages.length); // candidates, tail carved from the end

    // Keep the freshest tail messages; drop from the front of the droppable
    // window until under target (or nothing left to drop).
    final kept = List<ChatMessage>.of(droppable);
    var dropped = 0;
    while (kept.length > keepTailMessages && _estimate([...head, ...tail, ...kept]) + 16 > targetTokens) {
      kept.removeAt(0);
      dropped++;
    }

    if (dropped == 0) {
      return CompressionResult(region: region, tokensSaved: 0, lossy: false);
    }

    final omittedTokens = before - _estimate([...head, ...kept]);
    final marker = ChatMessage.user(
      '[context truncated: $dropped message(s), ~$omittedTokens tokens '
      'omitted from "${region.label}"]',
    );

    final newMessages = [...head, marker, ...kept];
    final after = _estimate(newMessages);
    final compressed = region.copyWith(
      messages: newMessages,
      estimatedTokens: after,
      compression: CompressionInfo(
        compressorId: id,
        tokensBefore: before,
        sourceFingerprint: regionFingerprintOf(region),
        lossy: true,
      ),
    );

    return CompressionResult(region: compressed, tokensSaved: (before - after).clamp(0, before), lossy: true);
  }
}
