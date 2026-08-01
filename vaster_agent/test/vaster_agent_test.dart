import 'package:test/test.dart';
import 'package:vaster_agent/vaster_agent.dart';

void main() {
  group('AgentDescriptor & Task & Output', () {
    test('AgentDescriptor json roundtrip', () {
      const descriptor = AgentDescriptor(
        agentId: 'ag_1',
        name: 'ResearchAgent',
        role: 'Researcher',
        systemInstruction: 'Search and summarize info.',
        allowedToolNames: ['search_web', 'read_file'],
      );

      final json = descriptor.toJson();
      final restored = AgentDescriptor.fromJson(json);

      expect(restored.agentId, equals('ag_1'));
      expect(restored.name, equals('ResearchAgent'));
      expect(restored.allowedToolNames, equals(['search_web', 'read_file']));
    });

    test('AgentTask & AgentOutput serialization', () {
      const task = AgentTask(
        taskId: 't_100',
        inputPrompt: 'Write a summary of quantum computing.',
      );
      expect(task.priority, equals(10));

      const output = AgentOutput(
        taskId: 't_100',
        agentId: 'ag_1',
        outputText: 'Quantum computing summary...',
        isSuccess: true,
      );

      final json = output.toJson();
      final restored = AgentOutput.fromJson(json);
      expect(restored.taskId, equals('t_100'));
      expect(restored.outputText, contains('Quantum computing'));
    });
  });
}
