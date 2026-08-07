import 'dart:convert';

import 'package:vaster_agent/vaster_agent.dart';
import 'package:vaster_context/vaster_context.dart';
import 'package:vaster_model/vaster_model.dart';
import 'package:vaster_policy/vaster_policy.dart' show PolicyViolationException;
import 'package:vaster_resources/vaster_resources.dart';
import 'package:vaster_session/vaster_session.dart';
import 'package:vaster_tool_manager/vaster_tool_manager.dart';
import 'package:vaster_token_estimate/vaster_token_estimate.dart';

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
  final Future<VasterAgent> Function(AgentDescriptor subagentDescriptor, ModelSession parentSession)?
  subagentLauncher;

  /// Reports each model turn's usage (measured or a labeled estimate) to the
  /// owner that wired this agent, making tool-loop turns visible to metering
  /// per-call rather than only as a task-level rollup. Invoked before the
  /// tracker charge so the turn stays observable even when a quota trips.
  /// The agent stays unaware of pricing and telemetry — it only reports.
  final void Function(UsageMetadata usage, String modelName)? onTurnUsage;

  /// Records tool effects inside the dispatch's effect region (GAP-3a):
  /// a retried task replays recorded results instead of re-executing
  /// side effects. The region rides task metadata
  /// ([EffectRegion.metadataKey]); with none — or with the canonical
  /// no-op recorder — calls execute directly.
  final ToolEffectRecorder toolEffectRecorder;

  /// Gates every tool call this agent makes (A1). The VM wires the
  /// program-policy binding here; a descriptor-declared agent policy
  /// composes on top at the VM's construction site.
  final ToolCallGate toolCallGate;

  BasicVasterAgent({
    required this.descriptor,
    required this.session,
    required this.resourceTracker,
    required this.toolManager,
    this.subagentLauncher,
    this.onTurnUsage,
    this.toolEffectRecorder = const NoopToolEffectRecorder(),
    this.toolCallGate = const NoopToolCallGate(),
  });

  @override
  String get agentId => descriptor.agentId;

  @override
  Future<AgentOutput> run(AgentTask task, {CancellationToken? cancelToken}) async {
    cancelToken?.throwIfCancelled();
    final watch = Stopwatch()..start();
    final subagentOutputs = <AgentOutput>[];
    // This agent's own usage, accumulated across every tool-loop turn. When a
    // backend reports nothing, a labeled estimate stands in so the total is
    // never silently zero.
    var taskUsage = const UsageMetadata();

    try {
      // ── ① Resolve tool definitions filtered by descriptor whitelist ──────────
      final resolvedTools = _resolveTools();

      // ── ② Record initial user message in session history ─────────────────────
      // The prompt is the task's input, verbatim. The task id is machine
      // bookkeeping (events, outputs, outcome registers) and must never
      // leak into model-visible text: ids derived from program counters
      // made every recorded tape's fingerprints — and every prompt-cache
      // prefix — invalid under ANY lowering change.
      session.appendMessage(ChatMessage.user(task.inputPrompt));

      // ── ③ Model → tool → model loop ──────────────────────────────────────────
      ModelResponse? response;
      for (var loop = 0; loop < descriptor.maxToolCallLoops; loop++) {
        cancelToken?.throwIfCancelled();

        // a. Compile context from session's context manager
        final budget = TokenBudget(
          maxContextTokens: session.model.capabilities.maxContextTokens,
          reservedOutputTokens: session.model.capabilities.maxOutputTokens,
          // Reserve for the tool schemas actually attached to the request
          // (was a hardcoded 1000 regardless of tools).
          reservedToolTokens: _estimateToolTokens(resolvedTools),
        );
        final compiled = await session.contextManager.compileContext(budget: budget);
        final systemInstruction = compiled.systemInstruction;
        // History arrives through the heap (SessionHistorySource projects it);
        // concatenating session.history again would duplicate every turn.
        final messages = compiled.messages;

        // b. Build ModelRequest — agent owns this, not the session.
        // A responseSchema forwarded via task metadata becomes a structured-
        // output constraint (typed return value for the dispatching ISA op).
        // Cache hints forwarded the same way become cache breakpoints on the
        // agent's own requests — the dispatching runtime pins regions, and
        // without this the agent's (largest) prompts never hit the cache.
        final responseSchema = task.metadata['responseSchema'];
        final hintsMeta = task.metadata['cacheHints'];
        final cacheHints = [
          if (hintsMeta is List)
            for (final h in hintsMeta)
              if (h is Map) ContextCacheHint.fromJson(Map<String, dynamic>.from(h)),
        ];
        final request = ModelRequest(
          systemInstruction: systemInstruction,
          messages: messages,
          tools: resolvedTools,
          cancelToken: cancelToken,
          cacheHints: cacheHints,
          generationConfig: responseSchema is Map
              ? GenerationConfig(responseSchema: Map<String, dynamic>.from(responseSchema))
              : const GenerationConfig(),
        );

        // c. Generate and track token usage. The model call is its own
        //    classification boundary: its failures become
        //    TaskModelFailure with the transient bit — the datum
        //    Resilient's retry decision reads.
        try {
          response = await session.model.generate(request);
        } on CancelledException {
          rethrow;
        } on QuotaExceededException {
          rethrow;
        } catch (e) {
          watch.stop();
          return AgentOutput(
            taskId: task.taskId,
            agentId: agentId,
            outputText: '',
            outcome: TaskModelFailure(message: '$e', transient: defaultIsTransient(e)),
            subagentOutputs: subagentOutputs,
            usage: taskUsage,
            executionDuration: watch.elapsed,
          );
        }
        final turnUsage = response.usage.totalTokenCount > 0
            ? response.usage
            : TokenEstimate.forExchange(
                prompt: request.messages.map((m) => m.text).join('\n'),
                output: response.text,
              );
        taskUsage += turnUsage;
        // A fallback-chain member that served the turn stamps servedBy —
        // attribution (and pricing) follows the model that really ran,
        // not the chain's head.
        onTurnUsage?.call(turnUsage, response.servedBy ?? session.model.modelName);
        resourceTracker.consumeTokens(turnUsage.totalTokenCount);

        // d. Record the model turn in session history
        session.appendMessage(response.message);

        // e. No tool calls → done
        final calls = response.functionCalls.toList();
        if (calls.isEmpty) break;

        // f. Execute the turn through the SHARED guarded pipeline (A1):
        //    the same ToolTurnRunner the ISA loop uses — gated by the
        //    program policy the runtime bound plus any descriptor policy,
        //    effect-replayed inside the dispatch's region, parallel by
        //    declaration.
        final runner = ToolTurnRunner(
          gate: toolCallGate,
          recorder: toolEffectRecorder,
          dispatch: toolManager.executeCall,
          concurrency: ToolTurnConcurrency.parallel,
        );
        final outcome = await runner.run(ToolTurn(calls), region: EffectRegion.fromMetadata(task.metadata));

        // h. Record quota for calls that really EXECUTED — replays
        //    perform no work and never count against the ceiling.
        if (outcome.executedCount > 0) {
          resourceTracker.recordToolCall(count: outcome.executedCount);
        }

        // i. One tool-role message per turn — the provider batching rule
        //    is a property of ToolTurnOutcome now, not a comment.
        session.appendMessage(outcome.toToolMessage());

        // Loop-iteration boundary: expire ephemeral scratch context.
        session.contextManager.pruneLifetimes({ContextLifetime.ephemeral});
      }

      // Task (step) boundary: expire ephemeral + step-scoped context.
      session.contextManager.pruneLifetimes({ContextLifetime.ephemeral, ContextLifetime.step});

      watch.stop();
      return AgentOutput(
        taskId: task.taskId,
        agentId: agentId,
        outputText: response?.text ?? '',
        subagentOutputs: subagentOutputs,
        usage: taskUsage,
        executionDuration: watch.elapsed,
      );
    } on CancelledException catch (e) {
      watch.stop();
      return AgentOutput(
        taskId: task.taskId,
        agentId: agentId,
        outputText: '',
        outcome: TaskCancelled(message: e.message),
        subagentOutputs: subagentOutputs,
        usage: taskUsage,
        executionDuration: watch.elapsed,
      );
    } on QuotaExceededException catch (e) {
      watch.stop();
      return AgentOutput(
        taskId: task.taskId,
        agentId: agentId,
        outputText: '',
        // The discriminator survives as data now, not prose.
        outcome: TaskQuotaExceeded(
          resourceType: e.resourceType,
          currentUsage: e.currentUsage,
          quotaLimit: e.quotaLimit,
          message: e.message,
        ),
        subagentOutputs: subagentOutputs,
        usage: taskUsage,
        executionDuration: watch.elapsed,
      );
    } on PolicyViolationException {
      // A1: a policy violation is a VM security trap, never a task
      // outcome — it must escape the agent, the mailbox, and every
      // program-level handler untouched.
      rethrow;
    } catch (e, st) {
      watch.stop();
      return AgentOutput(
        taskId: task.taskId,
        agentId: agentId,
        outputText: '',
        outcome: TaskFailure(error: '$e', stackTrace: '$st'),
        subagentOutputs: subagentOutputs,
        usage: taskUsage,
        executionDuration: watch.elapsed,
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
        onTurnUsage: onTurnUsage,
        // Subagents inherit the recorder AND the gate: their tool
        // effects belong to the same dispatch region, and they answer
        // to the same policy as their parent (A1).
        toolEffectRecorder: toolEffectRecorder,
        toolCallGate: toolCallGate,
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
  /// Token reservation for the tool schemas attached to each request —
  /// estimated from the serialized definitions actually sent.
  static int _estimateToolTokens(List<ToolDefinition> tools) =>
      tools.fold(0, (sum, t) => sum + TokenEstimate.forText(jsonEncode(t.toJson())));

  List<ToolDefinition> _resolveTools() {
    final all = toolManager.compiledDefinitions;
    if (descriptor.allowedToolNames.isEmpty) return all;
    final allowed = descriptor.allowedToolNames.toSet();
    return all.where((t) => allowed.contains(t.name)).toList();
  }
}
