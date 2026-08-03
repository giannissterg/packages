import 'package:vaster_context/vaster_context.dart';

/// A pluggable transformation that shrinks a [ContextRegion] to (approximately)
/// a target token count.
abstract interface class ContextCompressor {
  /// Stable identifier recorded into [CompressionInfo.compressorId].
  String get id;

  /// The strongest [ContextCompressibility] level this compressor implements.
  /// A `summarize`-level compressor may be applied to `summarize` regions; a
  /// `truncate`-level compressor to both `truncate` and (as fallback)
  /// `summarize` regions.
  ContextCompressibility get level;

  /// Compresses [region] toward [targetTokens]. Implementations must return a
  /// region with the same id, updated messages + estimatedTokens, and a
  /// populated [ContextRegion.compression]. Must never throw for recoverable
  /// conditions — degrade instead.
  Future<CompressionResult> compress(ContextRegion region,
      {required int targetTokens});
}

/// Outcome of one region compression.
final class CompressionResult {
  /// The compressed region (same id, new content, compression info attached).
  final ContextRegion region;

  /// Estimated tokens saved (before - after; never negative).
  final int tokensSaved;

  /// Whether original content was discarded.
  final bool lossy;

  const CompressionResult({
    required this.region,
    required this.tokensSaved,
    required this.lossy,
  });
}
