import 'package:vaster_model/vaster_model.dart';

/// Provenance record attached to a [ContextRegion] that has been compressed.
///
/// [sourceFingerprint] is the SHA-256 of the *original* (pre-compression)
/// content — it lets source syncs recognize that a compressed region still
/// shadows the same underlying content and must not be clobbered.
final class CompressionInfo {
  /// Identifier of the compressor that produced this region
  /// (e.g. `truncating`, `summarizing:claude-opus-5`).
  final String compressorId;

  /// Estimated tokens before compression.
  final int tokensBefore;

  /// SHA-256 hex fingerprint of the original content.
  final String sourceFingerprint;

  /// When the compression happened.
  final DateTime compressedAt;

  /// Whether original content was discarded ([originalMessages] == null).
  final bool lossy;

  /// The original messages, retained when the compressor preserves originals
  /// — enables expand/undo.
  final List<ChatMessage>? originalMessages;

  CompressionInfo({
    required this.compressorId,
    required this.tokensBefore,
    required this.sourceFingerprint,
    DateTime? compressedAt,
    this.lossy = true,
    this.originalMessages,
  }) : compressedAt = compressedAt ?? DateTime.now();

  Map<String, dynamic> toJson() => {
        'compressorId': compressorId,
        'tokensBefore': tokensBefore,
        'sourceFingerprint': sourceFingerprint,
        'compressedAt': compressedAt.toIso8601String(),
        'lossy': lossy,
        if (originalMessages != null)
          'originalMessages': [for (final m in originalMessages!) m.toJson()],
      };

  factory CompressionInfo.fromJson(Map<String, dynamic> json) =>
      CompressionInfo(
        compressorId: json['compressorId'] as String,
        tokensBefore: (json['tokensBefore'] as num).toInt(),
        sourceFingerprint: json['sourceFingerprint'] as String,
        compressedAt: DateTime.parse(json['compressedAt'] as String),
        lossy: json['lossy'] as bool? ?? true,
        originalMessages: json['originalMessages'] == null
            ? null
            : [
                for (final m in json['originalMessages'] as List)
                  ChatMessage.fromJson(Map<String, dynamic>.from(m as Map)),
              ],
      );

  @override
  String toString() =>
      'CompressionInfo($compressorId, ${tokensBefore}tok before, lossy: $lossy)';
}
