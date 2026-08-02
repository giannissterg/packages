import 'package:vaster_agent/vaster_agent.dart';
import 'package:vaster_context/vaster_context.dart';
import 'package:vaster_model/vaster_model.dart';
import 'package:vaster_resources/vaster_resources.dart';
import 'package:vaster_session/vaster_session.dart';
import 'package:vaster_tool_manager/vaster_tool_manager.dart';

/// Concrete implementation of [VasterAgent] executing model turns,
/// tool dispatch loops, and subagent spawning into child sessions.
///
/// ### Ownership (Rule 5)
/// - [resourceTracker] is a required construction-time dependency.
///   Callers that want unlimited execution pass
///   `ResourceTracker(quota: ResourceQuota.unlimited)`.
/// - [descriptor.maxToolCallLoops] controls the maximum tool loop
///   iterations — a behavioral limit that belongs in the descriptor,
///   not in [run].
/// - [toolManager] is an optional construction-time dependency; agents
///   that need no tools are constructed without one.
class BasicVasterAgent implements VasterAgent {
  @override
  final AgentDescriptor descriptor;

  @override
  final ModelSession session;

  /// Resource quota tracker enforcing token and tool call limits.
  /// Required at construction time — never passed per-invocation.
  final ResourceTracker resourceTracker;

  final ToolManager toolManager;

  /// Subagent launcher callback to construct child sessions.
  final Future<VasterAgent> Function(
    AgentDescriptor subagentDescriptor,
    ModelSession parentSession,
  )? subagentLauncher;

  BasicVasterAgent({
    required this.descriptor,
    required this.session,
    required this.resourceTracker,
    required this.toolManager,
    this.subagentLauncher,
  });

  @override
  String get agentId => descriptor.agentId;

  @override
  Future<AgentOutput> run(
    AgentTask task, {
    CancellationToken? cancelToken,
  }) async {
    cancelToken?.throwIfCancelled();
    final watch = Stopwatch()..start();
    final subagentOutputs = <AgentOutput>[];

    try {
      // ── ① Resolve tool definitions filtered by descriptor whitelist ──────────
      final resolvedTools = _resolveTools();

      // ── ② Record initial user message in session history ─────────────────────
      session.appendMessage(
        ChatMessage.user('[Agent Task ${task.taskId}]: ${task.inputPrompt}'),
      );

      // ── ③ Model → tool → model loop ──────────────────────────────────────────
      ModelResponse? response;
      for (var loop = 0; loop < descriptor.maxToolCallLoops; loop++) {
        cancelToken?.throwIfCancelled();

        // a. Compile context from session's context manager
        final budget = TokenBudget(
          maxContextTokens: session.model.capabilities.maxContextTokens,
          reservedOutputTokens: session.model.capabilities.maxOutputTokens,
        );
        final compiled = await session.contextManager.compileContext(budget: budget);
        final systemInstruction = compiled.systemInstruction;
        final messages = [...compiled.messages];

        // b. Build ModelRequest — agent owns this, not the session
        final request = ModelRequest(
          systemInstruction: systemInstruction,
          messages: messages,
          tools: resolvedTools,
          cancelToken: cancelToken,
        );

        // c. Generate and track token usage
        response = await session.model.generate(request);
        resourceTracker.consumeTokens(
          response.usage.totalTokenCount > 0
              ? response.usage.totalTokenCount
              : (request.messages.fold<int>(
                      0, (s, m) => s + m.text.length) ~/
                  4) +
                  (response.text.length ~/ 4),
        );

        // d. Record the model turn in session history
        session.appendMessage(response.message);

        // e. No tool calls → done
        final calls = response.functionCalls.toList();
        if (calls.isEmpty) break;

        // f. Execute all tool calls in parallel
        final results = await Future.wait(calls.map(toolManager.executeCall));

        // h. Record quota for every tool call executed
        resourceTracker.recordToolCall(count: calls.length);

        // i. Batch all FunctionResponseParts into a single tool-role message.
        //    Both Gemini and OpenAI require all responses from one model turn to
        //    arrive together before the next generation — sending them separately
        //    produces a malformed turn structure that providers reject.
        final toolMessage = ChatMessage(
          role: Role.tool,
          parts: results.map((r) => r.toResponsePart()).toList(),
        );
        session.appendMessage(toolMessage);
      }

      watch.stop();
      return AgentOutput(
        taskId: task.taskId,
        agentId: agentId,
        outputText: response?.text ?? '',
        isSuccess: true,
        subagentOutputs: subagentOutputs,
        executionDuration: watch.elapsed,
      );
    } on QuotaExceededException catch (e) {
      watch.stop();
      return AgentOutput(
        taskId: task.taskId,
        agentId: agentId,
        outputText: '',
        isSuccess: false,
        subagentOutputs: subagentOutputs,
        executionDuration: watch.elapsed,
        errorDetails: 'Quota exceeded: ${e.message}',
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
  Future<VasterAgent> spawnSubagent({
    required AgentDescriptor descriptor,
    required VasterModel model,
    AgentTask? task,
  }) async {
    final childSessionId = '${session.sessionId}_sub_${descriptor.agentId}';

    final childSession = BasicModelSession(
      sessionId: childSessionId,
      model: model,
      contextManager: session.contextManager,
    );

    VasterAgent subagent;
    if (subagentLauncher != null) {
      subagent = await subagentLauncher!(descriptor, childSession);
    } else {
      subagent = BasicVasterAgent(
        descriptor: descriptor,
        session: childSession,
        resourceTracker: resourceTracker,
        toolManager: toolManager,
      );
    }

    if (task != null) {
      await subagent.run(task);
    }

    return subagent;
  }

  // ─── Helpers ───────────────────────────────────────────────────────────────

  /// Returns compiled [ToolDefinition]s filtered by [descriptor.allowedToolNames].
  /// An empty whitelist means all registered tools are exposed.
  List<ToolDefinition> _resolveTools() {
    final all = toolManager.compiledDefinitions;
    if (descriptor.allowedToolNames.isEmpty) return all;
    final allowed = descriptor.allowedToolNames.toSet();
    return all.where((t) => allowed.contains(t.name)).toList();
  }
}
