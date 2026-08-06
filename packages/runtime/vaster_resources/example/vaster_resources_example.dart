import 'package:vaster_resources/vaster_resources.dart';

void main() {
  print('=== Vaster Resource Tracker Example ===');

  final tracker = ResourceTracker(
    quota: const ResourceQuota(
      maxTokenBudget: 500,
      maxToolCallsPerTask: 5,
    ),
  );

  tracker.consumeTokens(200);
  tracker.recordToolCall();

  print('Consumed Tokens: ${tracker.consumedTokens} / 500');
  print('Tool Calls: ${tracker.toolCallCount} / 5');
  print('Done!');
}
