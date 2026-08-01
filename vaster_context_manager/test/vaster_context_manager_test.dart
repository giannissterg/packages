import 'package:test/test.dart';
import 'package:vaster_context/vaster_context.dart';
import 'package:vaster_context_manager/vaster_context_manager.dart';
import 'package:vaster_model/vaster_model.dart';

void main() {
  group('BasicContextManager & PriorityAllocationStrategy', () {
    test('BasicContextManager registers sources and compiles context within budget', () async {
      final ContextManager manager = BasicContextManager(
        sources: [
          MemoryContextSource(
            id: 'sys_mem',
            data: {'system': 'You are Vaster OS assistant.'},
          ),
          FileContextSource(
            id: 'file_1',
            filePath: 'ideas.md',
            content: 'Virtual context concepts and memory heap.',
          ),
        ],
      );

      final compiled = await manager.compileContext(
        budget: const TokenBudget(
          maxContextTokens: 1000,
          reservedOutputTokens: 100,
          reservedToolTokens: 0,
        ),
      );

      expect(compiled.systemInstruction?.text, equals('system: You are Vaster OS assistant.'));
      expect(compiled.messages.length, equals(1));
      expect(compiled.includedRegions.length, equals(2));
      expect(compiled.evictedRegions, isEmpty);
    });

    test('PriorityAllocationStrategy evicts lower priority regions when budget exceeded', () async {
      final manager = BasicContextManager();

      // Critical region
      manager.heap.addRegion(ContextRegion.text(
        id: 'r_sys',
        label: 'System',
        role: Role.system,
        text: 'System instruction text',
        estimatedTokens: 50,
        priority: ContextPriority.critical,
      ));

      // Ephemeral region (large)
      manager.heap.addRegion(ContextRegion.text(
        id: 'r_eph',
        label: 'Scratchpad',
        role: Role.user,
        text: 'Scratchpad data text',
        estimatedTokens: 200,
        priority: ContextPriority.ephemeral,
      ));

      // High priority region
      manager.heap.addRegion(ContextRegion.text(
        id: 'r_high',
        label: 'User Query',
        role: Role.user,
        text: 'Important task query',
        estimatedTokens: 30,
        priority: ContextPriority.high,
      ));

      // Limit available input budget to 90 tokens
      const tightBudget = TokenBudget(
        maxContextTokens: 190,
        reservedOutputTokens: 100,
        reservedToolTokens: 0,
      );

      final compiled = await manager.compileContext(budget: tightBudget);

      expect(compiled.includedRegions.map((r) => r.id), containsAll(['r_sys', 'r_high']));
      expect(compiled.evictedRegions.map((r) => r.id), contains('r_eph'));
    });

    test('BasicContextManager prunes expired lifetimes', () {
      final manager = BasicContextManager();

      manager.heap.addRegion(ContextRegion.text(
        id: 'r_step',
        label: 'Step log',
        role: Role.user,
        text: 'Temporary step log',
        lifetime: ContextLifetime.step,
      ));
      manager.heap.addRegion(ContextRegion.text(
        id: 'r_sess',
        label: 'Session log',
        role: Role.user,
        text: 'Long session log',
        lifetime: ContextLifetime.session,
      ));

      expect(manager.heap.regions.length, equals(2));

      manager.pruneLifetimes({ContextLifetime.step});
      expect(manager.heap.regions.length, equals(1));
      expect(manager.heap.regions.first.id, equals('r_sess'));
    });
  });

  group('CompositeContextManager', () {
    test('composes multiple child ContextManagers and merges sources & compiled context', () async {
      final systemManager = BasicContextManager(
        sources: [
          MemoryContextSource(
            id: 'sys_source',
            data: {'system': 'Composite system prompt.'},
          ),
        ],
      );

      final fileManager = BasicContextManager(
        sources: [
          FileContextSource(
            id: 'doc_source',
            filePath: 'doc.txt',
            content: 'Document contents for VM.',
          ),
        ],
      );

      final ContextManager compositeManager = CompositeContextManager(
        children: [systemManager, fileManager],
      );

      expect(compositeManager.sources.length, equals(2));

      final compiled = await compositeManager.compileContext(
        budget: const TokenBudget(
          maxContextTokens: 1000,
          reservedOutputTokens: 100,
          reservedToolTokens: 0,
        ),
      );

      expect(compiled.systemInstruction?.text, equals('system: Composite system prompt.'));
      expect(compiled.includedRegions.length, equals(2));
      expect(compiled.messages.length, equals(1));
    });

    test('prunes lifetimes across all child managers', () {
      final child1 = BasicContextManager();
      child1.heap.addRegion(ContextRegion.text(
        id: 'c1_step',
        label: 'Step',
        role: Role.user,
        text: 'step 1',
        lifetime: ContextLifetime.step,
      ));

      final child2 = BasicContextManager();
      child2.heap.addRegion(ContextRegion.text(
        id: 'c2_sess',
        label: 'Session',
        role: Role.user,
        text: 'session 1',
        lifetime: ContextLifetime.session,
      ));

      final composite = CompositeContextManager(children: [child1, child2]);
      expect(composite.heap.regions.length, equals(2));

      composite.pruneLifetimes({ContextLifetime.step});
      expect(composite.heap.regions.length, equals(1));
      expect(composite.heap.regions.first.id, equals('c2_sess'));
    });
  });
}
