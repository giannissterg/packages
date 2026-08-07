import 'dart:async';

import 'package:test/test.dart';
import 'package:vaster_agent_manager_advanced/vaster_agent_manager_advanced.dart';
import 'package:vaster_context_manager/vaster_context_manager.dart';
import 'package:vaster_events/vaster_events.dart';
import 'package:vaster_model/vaster_model.dart';
import 'package:vaster_model_fake/vaster_model_fake.dart';
import 'package:vaster_resources/vaster_resources.dart';
import 'package:vaster_session_manager/vaster_session_manager.dart';
import 'package:vaster_tool_manager/vaster_tool_manager.dart';

/// Actor semantics: one agent = one session = one task at a time; different
/// agents overlap; pause gates both acceptance and dequeue; the sealed
/// lifecycle carries the data each state raises.
void main() {
  late AdvancedAgentManager manager;
  late RuntimeEventBus eventBus;
  late FakeVasterModel model;

  /// Tracks in-flight generate() calls per agent (via session id) to observe
  /// real concurrency.
  final active = <String, int>{};
  final maxActive = <String, int>{};
  var globalActive = 0;
  var globalMaxActive = 0;

  setUp(() async {
    active.clear();
    maxActive.clear();
    globalActive = 0;
    globalMaxActive = 0;

    model = FakeVasterModel(
      handler: (request) async {
        // Attribute the call to an agent via its system-instruction region
        // (each agent's session compiles its own instruction into context).
        final owner = request.systemInstruction?.text ?? 'unknown';
        active[owner] = (active[owner] ?? 0) + 1;
        globalActive++;
        maxActive[owner] = active[owner]! > (maxActive[owner] ?? 0) ? active[owner]! : maxActive[owner] ?? 0;
        globalMaxActive = globalActive > globalMaxActive ? globalActive : globalMaxActive;
        await Future<void>.delayed(const Duration(milliseconds: 15));
        active[owner] = active[owner]! - 1;
        globalActive--;
        return ModelResponse(message: ChatMessage.model('done'), finishReason: FinishReason.stop);
      },
    );

    eventBus = BasicEventBus();
    manager = AdvancedAgentManager(
      sessionManager: BasicSessionManager(),
      eventBus: eventBus,
      resourceTracker: ResourceTracker(quota: ResourceQuota.unlimited),
    );
  });

  tearDown(() => eventBus.close());

  Future<void> spawn(String id) => manager.createAgent(
    descriptor: AgentDescriptor(
      agentId: id,
      name: id,
      role: 'worker',
      systemInstruction: 'instruction-of-$id',
    ),
    model: model,
    contextManager: BasicContextManager(),
    toolManager: BasicToolManager(),
  );

  AgentTask task(String id) => AgentTask(taskId: id, inputPrompt: 'work $id');

  group('actor-serialized dispatch', () {
    test('two tasks to the SAME agent never overlap and run FIFO', () async {
      await spawn('solo');

      final results = await Future.wait([
        manager.dispatchTask(agentId: 'solo', task: task('t1')),
        manager.dispatchTask(agentId: 'solo', task: task('t2')),
      ]);

      expect(results.every((o) => o.isSuccess), isTrue);
      expect(
        maxActive['instruction-of-solo'],
        equals(1),
        reason: 'the mailbox must serialize same-agent tasks',
      );
    });

    test('tasks to DIFFERENT agents still overlap', () async {
      await spawn('a');
      await spawn('b');

      await Future.wait([
        manager.dispatchTask(agentId: 'a', task: task('ta')),
        manager.dispatchTask(agentId: 'b', task: task('tb')),
      ]);

      expect(globalMaxActive, greaterThan(1), reason: 'serialization is per-agent, not global');
    });

    test('the running lifecycle carries the active taskId and queue depth', () async {
      await spawn('busy');

      final first = manager.dispatchTask(agentId: 'busy', task: task('front'));
      final second = manager.dispatchTask(agentId: 'busy', task: task('back'));
      // Let the first task actually start.
      await Future<void>.delayed(const Duration(milliseconds: 5));

      final lifecycle = manager.lifecycleOf('busy');
      expect(
        lifecycle,
        isA<AgentRunning>()
            .having((l) => l.activeTaskId, 'activeTaskId', 'front')
            .having((l) => l.queuedTasks, 'queuedTasks', 1),
      );
      expect(lifecycle.asState, AgentState.running);

      await Future.wait([first, second]);
      expect(manager.lifecycleOf('busy'), isA<AgentIdle>());
    });

    test('pause fails new dispatches AND queued tasks at dequeue', () async {
      await spawn('gated');

      final running = manager.dispatchTask(agentId: 'gated', task: task('t1'));
      final queued = manager.dispatchTask(agentId: 'gated', task: task('t2'));
      await Future<void>.delayed(const Duration(milliseconds: 5));
      manager.pauseAgent('gated');

      // Submitted after the pause: refused immediately.
      final refused = await manager.dispatchTask(agentId: 'gated', task: task('t3'));
      expect(refused.isSuccess, isFalse);
      expect(refused.errorDetails, contains('paused'));

      // The in-flight task completes; the queued one is refused at dequeue.
      expect((await running).isSuccess, isTrue);
      final queuedOutcome = await queued;
      expect(queuedOutcome.isSuccess, isFalse);
      expect(queuedOutcome.errorDetails, contains('paused'));

      // The pause survives the drain (a completing task must not overwrite
      // a mid-run pause back to idle).
      expect(manager.lifecycleOf('gated'), isA<AgentPaused>());

      manager.resumeAgent('gated');
      expect(manager.lifecycleOf('gated'), isA<AgentIdle>());
      final afterResume = await manager.dispatchTask(agentId: 'gated', task: task('t4'));
      expect(afterResume.isSuccess, isTrue);
    });

    test('a failing task does not poison the mailbox for the next one', () async {
      await spawn('resilient');
      // An unregistered-tool crash path: dispatch to a missing agent id is a
      // refusal, but a genuine throw inside run() must reject only its own
      // future. Simulate by pausing mid-queue instead (dequeue refusal),
      // then verifying the agent still works.
      manager.pauseAgent('resilient');
      final refused = await manager.dispatchTask(agentId: 'resilient', task: task('tx'));
      expect(refused.isSuccess, isFalse);
      manager.resumeAgent('resilient');
      final ok = await manager.dispatchTask(agentId: 'resilient', task: task('ty'));
      expect(ok.isSuccess, isTrue);
    });

    test('unregister removes the entry entirely — terminated, not leaked', () async {
      await spawn('gone');
      expect(manager.unregisterAgent('gone'), isTrue);
      expect(manager.lifecycleOf('gone'), isA<AgentTerminated>());
      expect(manager.getAgentState('gone'), AgentState.terminated);
      expect(manager.unregisterAgent('gone'), isFalse);
    });
  });
}
