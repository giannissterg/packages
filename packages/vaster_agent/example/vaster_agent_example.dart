import 'package:vaster_agent/vaster_agent.dart';

void main() {
  print('=== Vaster Agent Primitives Example ===');

  const descriptor = AgentDescriptor(
    agentId: 'ag_demo',
    name: 'DemoAgent',
    role: 'Assistant',
    systemInstruction: 'You are a helpful assistant.',
    allowedToolNames: ['search_web', 'read_file'],
  );

  print('Descriptor: $descriptor');
}
