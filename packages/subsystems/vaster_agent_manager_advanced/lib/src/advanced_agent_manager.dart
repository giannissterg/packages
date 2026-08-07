import 'dart:async';
import 'package:vaster_agent_basic/vaster_agent_basic.dart';
import 'package:vaster_agent_manager/vaster_agent_manager.dart';
import 'package:vaster_context/vaster_context.dart';
import 'package:vaster_context_manager/vaster_context_manager.dart';
import 'package:vaster_events/vaster_events.dart';
import 'package:vaster_model/vaster_model.dart';
import 'package:vaster_resources/vaster_resources.dart';
import 'package:vaster_session_manager/vaster_session_manager.dart';
import 'package:vaster_tool_manager/vaster_tool_manager.dart';
import 'package:vaster_token_estimate/vaster_token_estimate.dart';

import 'agent_mailbox.dart';

/// Everything the manager knows about one agent, in one place.
///
/// Composition replaces the four parallel maps the manager used to keep
/// (`_agents` / `_states` / `_parents` / `_children`) — a structure where
/// every mutation had to touch the right subset of maps or drift silently
/// (unregister used to leave a terminated entry in `_states` forever).
final class _AgentEntry {
  final VasterAgent agent;
  AgentLifecycle lifecycle = const AgentIdle();
  final String? parentId;
  final List<String> childIds = [];
  final AgentMailbox mailbox = AgentMailbox();

  _AgentEntry(this.agent, {this.parentId});
}

/// Advanced supervisor implementation of [AgentManager]: supervisor trees,
/// actor-serialized per-agent dispatch, parallel dispatch across agents,
/// sealed lifecycle states, and [RuntimeEventBus] telemetry.
///
/// ### Actor semantics
/// Tasks for the same agent are serialized FIFO through the agent's
/// [AgentMailbox] — one session, one transcript, one task at a time. Tasks
/// for different agents run concurrently. [pauseAgent] gates both acceptance
/// and dequeue: new dispatches fail immediately, and tasks already queued
/// fail when their turn comes while the agent is still paused.
class AdvancedAgentManager implements AgentManager {
  final SessionManager sessionManager;
  final RuntimeEventBus eventBus;
  final ResourceTracker resourceTracker;
  final int maxTreeDepth;

  /// Per-turn usage listener wired into every agent this manager creates.
  /// When installed, its owner (the VM's meter) owns usage telemetry at turn
  /// granularity and this manager suppresses its own task-level
  /// [ModelUsageEvent] rollup — emitting both would double-count every task
  /// in any consumer that sums usage events.
  final void Function(UsageMetadata usage, String modelName)? onTurnUsage;

  /// Effect recorder wired into every agent this manager creates
  /// (GAP-3a): inside a dispatch's effect region, agent tool calls
  /// replay recorded results across retry attempts. The canonical no-op
  /// default records nothing.
  final ToolEffectRecorder toolEffectRecorder;

  final Map<String, _AgentEntry> _entries = {};

  AdvancedAgentManager({
    required this.sessionManager,
    required this.eventBus,
    required this.resourceTracker,
    this.maxTreeDepth = 5,
    this.onTurnUsage,
    this.toolEffectRecorder = const NoopToolEffectRecorder(),
    List<VasterAgent> initialAgents = const [],
  }) {
    for (final agent in initialAgents) {
      registerAgent(agent);
    }
  }

  @override
  List<AgentDescriptor> get activeDescriptors =>
      List.unmodifiable(_entries.values.map((e) => e.agent.descriptor));

  @override
  List<VasterAgent> get activeAgents =>
      List.unmodifiable(_entries.values.map((e) => e.agent));

  @override
  VasterAgent? registerAgent(VasterAgent agent, {String? parentAgentId}) {
    final displaced = _entries[agent.agentId]?.agent;
    _entries[agent.agentId] = _AgentEntry(agent, parentId: parentAgentId);
    if (parentAgentId != null) {
      _entries[parentAgentId]?.childIds.add(agent.agentId);
    }
    return displaced;
  }

  @override
  bool unregisterAgent(String agentId) {
    final entry = _entries.remove(agentId);
    if (entry == null) return false;
    if (entry.parentId != null) {
      _entries[entry.parentId]?.childIds.remove(agentId);
    }
    return true;
  }

  @override
  VasterAgent? getAgent(String agentId) => _entries[agentId]?.agent;

  /// The agent's full lifecycle position (sealed, data-carrying). Unknown
  /// agents are [AgentTerminated].
  AgentLifecycle lifecycleOf(String agentId) =>
      _entries[agentId]?.lifecycle ?? const AgentTerminated();

  @override
  AgentState getAgentState(String agentId) => lifecycleOf(agentId).asState;

  /// Pauses an agent: new dispatches fail immediately and queued tasks fail
  /// when dequeued while still paused.
  void pauseAgent(String agentId) {
    final entry = _entries[agentId];
    if (entry != null) entry.lifecycle = const AgentPaused();
  }

  /// Resumes a paused agent.
  void resumeAgent(String agentId) {
    final entry = _entries[agentId];
    if (entry != null && entry.lifecycle is AgentPaused) {
      entry.lifecycle = const AgentIdle();
    }
  }

  /// Returns supervisor tree node info for an agent.
  AgentTreeNode? getTreeNode(String agentId) {
    final entry = _entries[agentId];
    if (entry == null) return null;

    return AgentTreeNode(
      descriptor: entry.agent.descriptor,
      state: entry.lifecycle.asState,
      parentAgentId: entry.parentId,
      childAgentIds: List.unmodifiable(entry.childIds),
    );
  }

  @override
  Future<VasterAgent> createAgent({
    required AgentDescriptor descriptor,
    required VasterModel model,
    required ContextManager contextManager,
    required ToolManager toolManager,
    String? parentAgentId,
  }) async {
    if (parentAgentId != null) {
      int depth = _calculateDepth(parentAgentId);
      if (depth >= maxTreeDepth) {
        throw StateError(
            'Cannot spawn subagent: Supervisor tree depth limit ($maxTreeDepth) reached.');
      }
    }

    final sessionId = AgentDescriptor.sessionIdFor(descriptor.agentId);
    // Get-or-create: after a checkpoint restore the agent's session already
    // exists (with its restored history) while the agent object does not —
    // recreating the agent must adopt that session, not throw on the
    // duplicate id. For an existing session the passed contextManager is
    // unused (the session keeps the one it was restored with).
    final session = sessionManager.getSession(sessionId) ??
        await sessionManager.createSession(
          sessionId: sessionId,
          model: model,
          contextManager: contextManager,
        );

    // Project the agent's system instruction into the heap as a system-class
    // region so it actually reaches ModelRequest.systemInstruction — before
    // this, descriptor.systemInstruction never left the descriptor.
    if (descriptor.systemInstruction.trim().isNotEmpty) {
      session.contextManager.addRegion(ContextRegion.text(
        id: 'system:agent:${descriptor.agentId}',
        label: 'agent "${descriptor.agentId}" system instruction',
        role: Role.system,
        text: descriptor.systemInstruction,
        classId: ContextClassTable.systemClassName,
        isPinned: true,
      ));
    }

    final agent = BasicVasterAgent(
      descriptor: descriptor,
      session: session,
      resourceTracker: resourceTracker,
      toolManager: toolManager,
      onTurnUsage: onTurnUsage,
      toolEffectRecorder: toolEffectRecorder,
    );

    registerAgent(agent, parentAgentId: parentAgentId);
    return agent;
  }

  @override
  Future<AgentOutput> dispatchTask({
    required String agentId,
    required AgentTask task,
  }) {
    final entry = _entries[agentId];
    if (entry == null) {
      return Future.value(_refusal(agentId, task,
          'Agent "$agentId" is not registered in AdvancedAgentManager.'));
    }
    if (entry.lifecycle is AgentPaused) {
      return Future.value(
          _refusal(agentId, task, 'Agent "$agentId" is currently paused.'));
    }

    // Actor rule: one task at a time per agent, FIFO. Acceptance is visible
    // immediately in the lifecycle's queue depth.
    final result = entry.mailbox.enqueue(() => _runTask(entry, task));
    if (entry.lifecycle case AgentRunning(:final activeTaskId)) {
      entry.lifecycle = AgentRunning(
        activeTaskId: activeTaskId,
        queuedTasks: entry.mailbox.pendingTasks - 1,
      );
    }
    return result;
  }

  /// Executes one dequeued task with lifecycle transitions and telemetry.
  Future<AgentOutput> _runTask(_AgentEntry entry, AgentTask task) async {
    final agentId = entry.agent.agentId;
    // A pause that landed while this task sat in the queue wins.
    if (entry.lifecycle is AgentPaused) {
      return _refusal(agentId, task, 'Agent "$agentId" is currently paused.');
    }

    entry.lifecycle = AgentRunning(
      activeTaskId: task.taskId,
      queuedTasks: entry.mailbox.pendingTasks - 1,
    );

    eventBus.publish(ModelStartedEvent(
      eventId: 'evt_start_${task.taskId}',
      sessionId: entry.agent.session.sessionId,
      modelName: entry.agent.session.model.modelName,
      promptTokenCount: TokenEstimate.forText(task.inputPrompt),
      metadata: const {'estimated': true},
    ));

    try {
      final output = await entry.agent.run(task);

      final aggregate = output.aggregateUsage;
      eventBus.publish(ModelFinishedEvent(
        eventId: 'evt_finish_${task.taskId}',
        sessionId: entry.agent.session.sessionId,
        finishReason: output.isSuccess ? 'stop' : 'error',
        totalTokens: aggregate.totalTokenCount > 0
            ? aggregate.totalTokenCount
            : TokenEstimate.forText(output.outputText),
        executionDuration: output.executionDuration,
        metadata: {
          if (aggregate.totalTokenCount == 0) 'estimated': true,
        },
      ));
      // Task-level usage rollup — only when no per-turn listener is
      // installed. With [onTurnUsage] wired, its owner already emitted one
      // event per model turn; a rollup on top would double-count the task.
      // Cost is wire-reported only here — the manager owns no pricing
      // catalog.
      if (onTurnUsage == null) {
        eventBus.publish(ModelUsageEvent(
          eventId: 'evt_usage_${task.taskId}',
          modelName: entry.agent.session.model.modelName,
          callSite: 'agent_task',
          promptTokenCount: aggregate.promptTokenCount,
          candidatesTokenCount: aggregate.candidatesTokenCount,
          totalTokenCount: aggregate.totalTokenCount,
          costUsd: aggregate.costUsd,
          estimated: aggregate.source == UsageSource.estimated,
          usage: aggregate.toJson(),
        ));
      }

      return output;
    } finally {
      // Exhaustive by construction: only a still-running agent returns to
      // idle — a pause issued mid-task sticks, and a concurrent unregister
      // leaves no entry to touch.
      entry.lifecycle = switch (entry.lifecycle) {
        AgentRunning() => const AgentIdle(),
        final other => other,
      };
    }
  }

  static AgentOutput _refusal(String agentId, AgentTask task, String reason) =>
      AgentOutput(
        taskId: task.taskId,
        agentId: agentId,
        outputText: '',
        outcome: TaskRefused(reason: reason),
      );

  @override
  Future<AgentOutput> dispatchDescriptorTask({
    required AgentDescriptor agentDescriptor,
    required AgentTask task,
  }) =>
      dispatchTask(agentId: agentDescriptor.agentId, task: task);

  /// Dispatches multiple tasks in parallel — concurrent across agents,
  /// serialized per agent (see the actor semantics above).
  @override
  Future<List<AgentOutput>> dispatchParallelTasks(
    List<({String agentId, AgentTask task})> dispatches,
  ) async {
    final futures = dispatches.map((d) => dispatchTask(
          agentId: d.agentId,
          task: d.task,
        ));
    return await Future.wait(futures);
  }

  int _calculateDepth(String agentId) {
    int depth = 1;
    String? current = _entries[agentId]?.parentId;
    while (current != null) {
      depth++;
      current = _entries[current]?.parentId;
    }
    return depth;
  }
}
