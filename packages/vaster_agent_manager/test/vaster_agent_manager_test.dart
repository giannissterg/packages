import 'package:test/test.dart';
import 'package:vaster_agent_manager/vaster_agent_manager.dart';

void main() {
  group('AgentState & AgentTreeNode', () {
    test('AgentState enum values', () {
      expect(AgentState.values, contains(AgentState.idle));
      expect(AgentState.values, contains(AgentState.running));
      expect(AgentState.values, contains(AgentState.paused));
      expect(AgentState.values, contains(AgentState.terminated));
    });

    test('AgentTreeNode construction', () {
      const node = AgentTreeNode(
        descriptor: AgentDescriptor(
          agentId: 'a1',
          name: 'AgentOne',
          role: 'Role',
          systemInstruction: 'Inst',
        ),
        state: AgentState.idle,
      );

      expect(node.descriptor.agentId, equals('a1'));
      expect(node.state, equals(AgentState.idle));
    });
  });
}
