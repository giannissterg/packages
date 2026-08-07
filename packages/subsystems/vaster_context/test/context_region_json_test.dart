import 'dart:convert';

import 'package:test/test.dart';
import 'package:vaster_context/vaster_context.dart';
import 'package:vaster_model/vaster_model.dart';

/// Checkpoint fidelity: a region survives JSON byte-exactly, including the
/// null-vs-explicit policy distinction class inheritance depends on.
void main() {
  group('ContextRegion JSON round-trip', () {
    test('a fully-specified region round-trips field for field', () {
      final region = ContextRegion(
        id: 'brief',
        label: 'project brief',
        messages: [ChatMessage.user('build a notes app'), ChatMessage.model('understood')],
        estimatedTokens: 42,
        classId: 'knowledge',
        priority: ContextPriority.high,
        lifetime: ContextLifetime.step,
        isPinned: true,
        utility: 0.75,
        metadata: const {'origin': 'test', 'rank': 3},
        compressibility: ContextCompressibility.truncate,
        order: 7,
        compression: CompressionInfo(
          compressorId: 'summarizing:fake',
          tokensBefore: 90,
          sourceFingerprint: 'abc123',
          lossy: false,
          originalMessages: [ChatMessage.user('the original')],
        ),
      );

      final restored = ContextRegion.fromJson(
        jsonDecode(jsonEncode(region.toJson())) as Map<String, dynamic>,
      );

      expect(restored.id, region.id);
      expect(restored.label, region.label);
      expect(restored.messages.map((m) => m.text), equals(region.messages.map((m) => m.text)));
      expect(restored.estimatedTokens, region.estimatedTokens);
      expect(restored.classId, region.classId);
      expect(restored.priority, region.priority);
      expect(restored.lifetime, region.lifetime);
      expect(restored.isPinned, isTrue);
      expect(restored.utility, region.utility);
      expect(restored.metadata, equals(region.metadata));
      expect(restored.compressibility, region.compressibility);
      expect(restored.order, region.order);
      expect(restored.compression, isNotNull);
      expect(restored.compression!.compressorId, 'summarizing:fake');
      expect(restored.compression!.lossy, isFalse);
      expect(restored.compression!.originalMessages, hasLength(1));
      expect(restored.isCompressed, isTrue);
    });

    test('null policy overrides stay null — inherit-from-class survives', () {
      const region = ContextRegion(id: 'minimal', label: 'minimal', messages: [], estimatedTokens: 0);
      final restored = ContextRegion.fromJson(
        jsonDecode(jsonEncode(region.toJson())) as Map<String, dynamic>,
      );

      expect(restored.priority, isNull, reason: 'explicit-vs-inherit is what makes class policy work');
      expect(restored.lifetime, isNull);
      expect(restored.compressibility, isNull);
      expect(restored.classId, isNull);
      expect(restored.compression, isNull);
      expect(restored.isPinned, isFalse);
    });
  });
}
