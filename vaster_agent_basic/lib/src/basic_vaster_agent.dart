import 'package:vaster_agent/vaster_agent.dart';
import 'package:vaster_model/vaster_model.dart';
import 'package:vaster_session/vaster_session.dart';
import 'package:vaster_tool_manager/vaster_tool_manager.dart';

/// Concrete implementation of [VasterAgent] executing model turns,
/// tool dispatch loops, and subagent spawning into child sessions.
class BasicVasterAgent implements VasterAgent {
  @override
  final AgentDescriptor descriptor;

  @override
  final ModelSession session;

  final ToolManager? toolManager;

  /// Subagent launcher callback to construct child sessions.
  final Future<VasterAgent> Function(
    AgentDescriptor subagentDescriptor,
    ModelSession parentSession,
  )? subagentLauncher;

  BasicVasterAgent({
    required this.descriptor,
    required this.session,
    this.toolManager,
    this.subagentLauncher,
  });

  @override
  String get agentId => descriptor.agentId;

  @override
  Future<AgentOutput> run(AgentTask task) async {
    final watch = Stopwatch()..start();
    final subagentOutputs = <AgentOutput>[];

    try {
      var response = await session.send(
        ChatMessage.user(
          '[Agent Task ${task.taskId}]: ${task.inputPrompt}',
        ),
      );

      // Tool dispatch loop if response contains function calls and toolManager is available
      int maxLoop = 5;
      while (response.functionCalls.isNotEmpty &&
          toolManager != null &&
          maxLoop > 0) {
        maxLoop--;
        final toolResponses =
            await toolManager!.processFunctionCalls(response.functionCalls);

        for (final toolMsg in toolResponses) {
          response = await session.send(toolMsg);
        }
      }

      watch.stop();
      return AgentOutput(
        taskId: task.taskId,
        agentId: agentId,
        outputText: response.text,
        isSuccess: true,
        subagentOutputs: subagentOutputs,
        executionDuration: watch.elapsed,
      );
    } catch (e, st) {
      watch.stop();
      return AgentOutput(
        taskId: task.taskId,
        agentId: agentId,
        outputText: '',
        isSuccess: false,
        subagentOutputs: subagentOutputs,
        executionDuration: watch.elapsed,
        errorDetails: '$e\n$st',
      );
    }
  }

  @override
  Future<AgentOutput> spawnSubagent({
    required AgentDescriptor subagentDescriptor,
    required AgentTask task,
  }) async {
    final childSessionId = '${session.sessionId}_sub_${subagentDescriptor.agentId}';

    final childSession = BasicModelSession(
      sessionId: childSessionId,
      model: session.model,
      contextManager: session.contextManager,
    );

    VasterAgent subagent;
    if (subagentLauncher != null) {
      subagent = await subagentLauncher!(subagentDescriptor, childSession);
    } else {
      subagent = BasicVasterAgent(
        descriptor: subagentDescriptor,
        session: childSession,
        toolManager: toolManager,
      );
    }

    return await subagent.run(task);
  }
}
