import 'package:vaster_agent_manager/vaster_agent_manager.dart';

void main() {
  print('=== Vaster Agent Manager Interface Example ===');

  const node = AgentTreeNode(
    descriptor: AgentDescriptor(
      agentId: 'interface_demo',
      name: 'InterfaceAgent',
      role: 'Role',
      systemInstruction: 'Instruction',
    ),
    state: AgentState.idle,
  );

  print('Agent State: ${node.state}');
  print('Done!');
}
