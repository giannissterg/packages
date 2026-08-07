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

      // 600 input tokens available (540 after allocation slack): both 500-token
      // regions cannot fit — the pinned one must survive.
      final compiled = await manager.compileContext(
        budget: const TokenBudget(maxContextTokens: 1000, reservedOutputTokens: 400, reservedToolTokens: 0),
      );

      final includedIds = compiled.includedRegions.map((r) => r.id).toList();
      expect(includedIds, contains('r_pinned'));
      expect(compiled.evictedRegions.map((r) => r.id), contains('r_low'));
    });

    test('a pinned region that cannot fit is a hard overflow error', () async {
      final manager = BasicContextManager();
      manager.heap.addRegion(
        ContextRegion.text(
          id: 'r_huge',
          label: 'Pinned but oversized',
          role: Role.user,
          text: 'huge',
          estimatedTokens: 5000,
          isPinned: true,
        ),
      );

      // Silently over-admitting a pinned region past the window used to ship
      // a request the provider would reject — now it fails at link time.
      await expectLater(
        manager.compileContext(
          budget: const TokenBudget(maxContextTokens: 1000, reservedOutputTokens: 400, reservedToolTokens: 0),
        ),
        throwsA(isA<ContextOverflowError>()),
      );
    });
  });
}
