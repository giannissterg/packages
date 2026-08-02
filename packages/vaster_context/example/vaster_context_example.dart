import 'package:vaster_context/vaster_context.dart';
import 'package:vaster_model/vaster_model.dart';

void main() {
  print('=== Vaster Context Primitives Example ===');

  final heap = ContextHeap([
    ContextRegion.text(
      id: 'sys',
      label: 'System instruction',
      role: Role.system,
      text: 'You are an execution agent.',
      priority: ContextPriority.critical,
    ),
    ContextRegion.text(
      id: 'usr',
      label: 'User prompt',
      role: Role.user,
      text: 'List files.',
      priority: ContextPriority.high,
    ),
  ]);

  print('Heap region count: ${heap.regions.length}');
  print('Total estimated tokens: ${heap.totalEstimatedTokens}');
}
