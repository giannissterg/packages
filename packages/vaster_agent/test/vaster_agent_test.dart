import 'package:test/test.dart';
import 'package:vaster_agent/vaster_agent.dart';
import 'package:vaster_model/vaster_model.dart';

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

    test('usage round-trips and legacy payloads default to zero', () {
      const output = AgentOutput(
        taskId: 't_1',
        agentId: 'ag_1',
        outputText: 'done',
        usage: UsageMetadata(
          promptTokenCount: 500,
          candidatesTokenCount: 100,
          costUsd: 0.01,
          source: UsageSource.measured,
        ),
      );

      final restored = AgentOutput.fromJson(output.toJson());
      expect(restored.usage.promptTokenCount, equals(500));
      expect(restored.usage.costUsd, equals(0.01));
      expect(restored.usage.source, equals(UsageSource.measured));

      // Payload written before the usage field existed.
      final legacy = AgentOutput.fromJson({
        'taskId': 't_old',
        'agentId': 'ag_old',
        'outputText': 'old',
      });
      expect(legacy.usage.totalTokenCount, equals(0));
      expect(legacy.usage.source, equals(UsageSource.estimated));
    });

    test('aggregateUsage folds the subagent tree, each node exactly once', () {
      const leaf = AgentOutput(
        taskId: 'leaf',
        agentId: 'l',
        outputText: '',
        usage: UsageMetadata(
            promptTokenCount: 10,
            candidatesTokenCount: 1,
            source: UsageSource.measured),
      );
      const mid = AgentOutput(
        taskId: 'mid',
        agentId: 'm',
        outputText: '',
        usage: UsageMetadata(
            promptTokenCount: 20,
            candidatesTokenCount: 2,
            source: UsageSource.measured),
        subagentOutputs: [leaf, leaf],
      );
      const root = AgentOutput(
        taskId: 'root',
        agentId: 'r',
        outputText: '',
        usage: UsageMetadata(
            promptTokenCount: 40,
            candidatesTokenCount: 4,
            source: UsageSource.measured),
        subagentOutputs: [mid],
      );

      final aggregate = root.aggregateUsage;
      expect(aggregate.promptTokenCount, equals(40 + 20 + 10 + 10));
      expect(aggregate.candidatesTokenCount, equals(4 + 2 + 1 + 1));
      expect(aggregate.source, equals(UsageSource.measured));
    });
  });
}
