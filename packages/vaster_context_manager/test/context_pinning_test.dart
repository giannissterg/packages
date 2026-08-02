import 'package:test/test.dart';
import 'package:vaster_context/vaster_context.dart';
import 'package:vaster_context_manager/vaster_context_manager.dart';
import 'package:vaster_model/vaster_model.dart';

void main() {
  group('Context Region Pinning', () {
    test('protects pinned context region from eviction during budget pressure', () async {
      final manager = BasicContextManager();

      final lowUnpinned = ContextRegion.text(
        id: 'r_low',
        label: 'Low Priority Unpinned',
        role: Role.user,
        text: 'Unpinned region text payload',
        estimatedTokens: 500,
        priority: ContextPriority.low,
      );

      final lowPinned = ContextRegion.text(
        id: 'r_pinned',
        label: 'Low Priority Pinned',
        role: Role.user,
        text: 'Pinned region text payload',
        estimatedTokens: 500,
        priority: ContextPriority.low,
        isPinned: true,
      );

      manager.heap.addAll([lowUnpinned, lowPinned]);

      // Compile with strict budget of 600 input tokens (cannot fit both 500+500=1000 tokens)
      final compiled = await manager.compileContext(
        budget: const TokenBudget(maxContextTokens: 1000, reservedOutputTokens: 400),
      );

      // Pinned region MUST be included even though budget pressure would evict low priority!
      final includedIds = compiled.includedRegions.map((r) => r.id).toList();
      expect(includedIds, contains('r_pinned'));
    });
  });
}
