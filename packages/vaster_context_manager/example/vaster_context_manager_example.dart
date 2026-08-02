import 'package:vaster_context/vaster_context.dart';
import 'package:vaster_context_manager/vaster_context_manager.dart';
import 'package:vaster_model/vaster_model.dart';

void main() async {
  print('=== Vaster Composable Context Manager Example ===');

  // Child 1: System & Governance Context Manager
  final systemContextManager = BasicContextManager(
    sources: [
      MemoryContextSource.fromMap(
        id: 'system_memory',
        data: {'system': 'You are an advanced agent in the Vaster LLM Runtime.'},
      ),
    ],
  );

  // Child 2: Workspace Files Context Manager
  final workspaceContextManager = BasicContextManager(
    sources: [
      FileContextSource(
        id: 'ideas_file',
        filePath: 'ideas.md',
        content: 'Virtual context system for LLM runtime execution.',
      ),
    ],
  );

  // Composite: Combine system and workspace context managers into a single manager
  final ContextManager compositeManager = CompositeContextManager(
    children: [systemContextManager, workspaceContextManager],
  );

  compositeManager.heap.addRegion(ContextRegion.text(
    id: 'user_prompt',
    label: 'User Prompt',
    role: Role.user,
    text: 'How does composite context management work in Vaster?',
    priority: ContextPriority.critical,
  ));

  print('Registered sources across composite manager: ${compositeManager.sources.map((s) => s.id).join(', ')}');

  print('\nCompiling unified context from composite manager...');
  final compiled = await compositeManager.compileContext(
    budget: const TokenBudget(
      maxContextTokens: 128000,
      reservedOutputTokens: 4096,
    ),
  );

  print('System instruction: ${compiled.systemInstruction?.text}');
  print('Compiled messages count: ${compiled.messages.length}');
  print('Total estimated tokens: ${compiled.totalEstimatedTokens}');
  print('Included regions: ${compiled.includedRegions.map((r) => r.label).join(', ')}');
  print('Evicted regions: ${compiled.evictedRegions.length}');

  print('\nDone!');
}
