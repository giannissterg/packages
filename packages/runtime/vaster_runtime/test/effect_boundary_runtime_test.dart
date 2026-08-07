import 'package:test/test.dart';
import 'package:vaster_model_fake/vaster_model_fake.dart';
import 'package:vaster_vm/vaster_vm.dart';

/// REL-P4: the effect boundary. Compensable effects (transactional VFS)
/// roll back when a failure is caught; non-compensable effects (external
/// tool calls) are recorded in an effect scope and REPLAYED on retry
/// instead of re-executed. Hand-assembled ISA throughout (Rule 1).
void main() {
  Future<(VasterVMEngine, VasterRuntime)> boot(FakeVasterModel model) async {
    final vm = await VasterVMEngine.bootstrap(
      config: VMConfig(defaultModel: model, rootMountPath: '/mem'),
    );
    final runtime = VasterRuntime(
      vm: vm,
      policy: ExecutionPolicy.unlimited,
      budget: ExecutionBudget.unlimited(),
      scheduler: BasicVasterScheduler(taskQueue: PriorityTaskQueue()),
    );
    return (vm, runtime);
  }

  group('transactional unwinding (the Transaction promise, made real)', () {
    test('a caught failure rolls the open transaction back before the catch '
        'block runs', () async {
      final (vm, runtime) = await boot(FakeVasterModel());

      const program = VasterProgram(
        programName: 'tx_auto_rollback',
        instructions: [
          MountFsOp(mountPrefix: '/mem'), // 0
          WriteFileOp(vfsPath: '/mem/state.txt', content: 'v1'), // 1
          PushErrorHandlerOp(targetPc: 7, errorVar: 'err'), // 2
          BeginTransactionOp(), // 3
          WriteFileOp(vfsPath: '/mem/state.txt', content: 'v2_partial'), // 4
          ReadFileOp(vfsPath: '/not_mounted/boom.txt', outputVar: 'never'), // 5
          CommitOp(), // 6 (never reached)
          ReadFileOp(vfsPath: '/mem/state.txt', outputVar: 'observed'), // 7
          HaltOp(), // 8
        ],
      );

      final state = await runtime.executeProgram(program);

      expect(state.status, RuntimeStatus.halted);
      expect(state.registers['err'], isNotNull);
      expect(
        state.registers['observed'],
        'v1',
        reason:
            'the abandoned transaction\'s partial write must be gone '
            'by the time the handler observes the file — this used to '
            'leak v2_partial',
      );
      expect(
        vm.fileSystemManager.transactionDepth,
        0,
        reason: 'no abandoned open transaction survives the catch',
      );
      await vm.shutdown();
    });
  });

  group('transaction pairing is observable (Rule 2)', () {
    test('an unpaired commit warns instead of silently no-opping', () async {
      final (vm, runtime) = await boot(FakeVasterModel());
      final warnings = <RuntimeWarningEvent>[];
      final sub = vm.eventBus.on<RuntimeWarningEvent>().listen(warnings.add);

      const program = VasterProgram(programName: 'unpaired_commit', instructions: [CommitOp(), HaltOp()]);
      final state = await runtime.executeProgram(program);
      await sub.cancel();

      expect(state.status, RuntimeStatus.halted);
      expect(
        warnings.map((w) => w.code),
        contains('transaction_unpaired'),
        reason:
            'a commit with no open transaction means rollback '
            'protection was silently lost somewhere — it must be visible',
      );
      await vm.shutdown();
    });
  });

  group('effect scopes — idempotency at the tool boundary', () {
    test('a retried attempt replays the executed tool call instead of '
        're-performing the side effect', () async {
      var generateCalls = 0;
      var alertsSent = 0;

      final model = FakeVasterModel(
        handler: (request) {
          generateCalls++;
          switch (generateCalls) {
            case 1: // attempt 1: ask for the tool
            case 3: // attempt 2: ask for the SAME tool call again
              return ModelResponse(
                message: ChatMessage(
                  role: Role.model,
                  parts: [
                    const TextPart('Sending the alert.'),
                    FunctionCallPart(
                      callId: 'call_$generateCalls',
                      name: 'send_alert',
                      arguments: const {'message': 'deploy failed'},
                    ),
                  ],
                ),
                finishReason: FinishReason.toolCalls,
              );
            case 2: // attempt 1 continuation: model dies AFTER the tool ran
              throw StateError('API error 500 mid-turn');
            default: // attempt 2 continuation: success
              return ModelResponse(message: ChatMessage.model('alert delivered'));
          }
        },
      );

      final (vm, runtime) = await boot(model);
      vm.registerTool(
        FunctionTool.define(
          name: 'send_alert',
          description: 'Send an alert (non-compensable side effect)',
          parametersSchema: const {
            'type': 'object',
            'properties': {
              'message': {'type': 'string'},
            },
          },
          handler: (args) {
            alertsSent++;
            return {'status': 'sent', 'id': 'alert_1'};
          },
        ),
      );

      final replayed = <ToolCallReplayedEvent>[];
      final sub = vm.eventBus.on<ToolCallReplayedEvent>().listen(replayed.add);

      // The canonical Resilient shape, hand-assembled, with its REL-P4
      // effect-scope brackets.
      const program = VasterProgram(
        programName: 'retry_dedup',
        instructions: [
          PushEffectScopeOp(), // 0
          SetRegisterOp(registerName: 'attempt', value: 0), // 1
          CompareRegisterOp(
            // 2 head
            leftVar: 'attempt',
            operator: 'lt',
            rightValue: 3,
            targetVar: 'cmp',
          ),
          JumpIfOp(conditionVar: 'cmp', targetPc: 5), // 3
          JumpOp(targetPc: 12), // 4 exhausted → end
          PushErrorHandlerOp(targetPc: 9, errorVar: 'retry_error'), // 5
          PromptOp(promptText: 'check the deploy', outputVar: 'out'), // 6
          PopErrorHandlerOp(), // 7
          JumpOp(targetPc: 12), // 8 success → end
          MarkEffectRetryOp(), // 9 catch
          IncrementRegisterOp(registerName: 'attempt'), // 10
          JumpOp(targetPc: 2), // 11 back-edge
          PopEffectScopeOp(), // 12 end
          HaltOp(), // 13
        ],
      );

      final state = await runtime.executeProgram(program);
      await sub.cancel();

      expect(state.status, RuntimeStatus.halted);
      expect(state.registers['out'], contains('alert delivered'));
      expect(state.registers['attempt'], 1, reason: 'attempt 1 failed, attempt 2 succeeded');
      expect(
        alertsSent,
        1,
        reason:
            'THE claim of REL-P4: the retried turn must not send the '
            'alert twice',
      );
      expect(replayed, hasLength(1));
      expect(replayed.single.toolName, 'send_alert');
      await vm.shutdown();
    });
  });

  group('agent dispatch dedup (GAP-2)', () {
    test('a retried attempt replays a completed task instead of re-running '
        'the agent', () async {
      var taskRuns = 0;
      var flakyCalls = 0;
      final model = FakeVasterModel(
        handler: (request) {
          final text = request.messages.last.text;
          if (text.contains('do the analysis')) {
            taskRuns++;
            return ModelResponse(message: ChatMessage.model('analysis done'));
          }
          // The step after the task: fails once, then succeeds.
          flakyCalls++;
          if (flakyCalls == 1) throw StateError('API error 500 flaky step');
          return ModelResponse(message: ChatMessage.model('step ok'));
        },
      );

      final (vm, runtime) = await boot(model);
      final replayed = <AgentTaskReplayedEvent>[];
      final sub = vm.eventBus.on<AgentTaskReplayedEvent>().listen(replayed.add);

      const program = VasterProgram(
        programName: 'task_dedup',
        instructions: [
          CreateAgentOp(
            descriptor: AgentDescriptor(
              agentId: 'analyst',
              name: 'Analyst',
              role: 'analysis',
              systemInstruction: 'Analyze.',
            ),
          ), // 0
          PushEffectScopeOp(), // 1
          SetRegisterOp(registerName: 'attempt', value: 0), // 2
          CompareRegisterOp(
            // 3 head
            leftVar: 'attempt',
            operator: 'lt',
            rightValue: 3,
            targetVar: 'cmp',
          ),
          JumpIfOp(conditionVar: 'cmp', targetPc: 6), // 4
          JumpOp(targetPc: 14), // 5 exhausted → end
          PushErrorHandlerOp(targetPc: 11, errorVar: 'retry_error'), // 6
          DispatchAgentTaskOp(agentId: 'analyst', taskPrompt: 'do the analysis', outputVar: 'analysis'), // 7
          PromptOp(promptText: 'flaky step after', outputVar: 'step'), // 8
          PopErrorHandlerOp(), // 9
          JumpOp(targetPc: 14), // 10 success → end
          MarkEffectRetryOp(), // 11 catch
          IncrementRegisterOp(registerName: 'attempt'), // 12
          JumpOp(targetPc: 3), // 13 back-edge
          PopEffectScopeOp(), // 14 end
          HaltOp(), // 15
        ],
      );

      final state = await runtime.executeProgram(program);
      await sub.cancel();

      expect(state.status, RuntimeStatus.halted);
      expect(state.registers['analysis'], contains('analysis done'));
      expect(state.registers['step'], contains('step ok'));
      expect(
        taskRuns,
        1,
        reason:
            'the completed task must not re-run when a LATER step '
            'fails the attempt',
      );
      expect(replayed, hasLength(1));
      expect(replayed.single.agentId, 'analyst');
      await vm.shutdown();
    });

    test('parallel batch: retried successes replay, only the failure '
        're-runs', () async {
      var aRuns = 0;
      var bRuns = 0;
      final model = FakeVasterModel(
        handler: (request) {
          final text = request.messages.last.text;
          if (text.contains('task A')) {
            aRuns++;
            return ModelResponse(message: ChatMessage.model('A done'));
          }
          if (text.contains('task B')) {
            bRuns++;
            if (bRuns == 1) throw StateError('API error 500 B down');
            return ModelResponse(message: ChatMessage.model('B done'));
          }
          return ModelResponse(message: ChatMessage.model('?'));
        },
      );

      final (vm, runtime) = await boot(model);

      const program = VasterProgram(
        programName: 'parallel_dedup',
        instructions: [
          CreateAgentOp(
            descriptor: AgentDescriptor(agentId: 'a', name: 'A', role: 'r', systemInstruction: 's'),
          ), // 0
          CreateAgentOp(
            descriptor: AgentDescriptor(agentId: 'b', name: 'B', role: 'r', systemInstruction: 's'),
          ), // 1
          PushEffectScopeOp(), // 2
          SetRegisterOp(registerName: 'attempt', value: 0), // 3
          CompareRegisterOp(
            // 4 head
            leftVar: 'attempt',
            operator: 'lt',
            rightValue: 3,
            targetVar: 'cmp',
          ),
          JumpIfOp(conditionVar: 'cmp', targetPc: 7), // 5
          JumpOp(targetPc: 14), // 6 exhausted → end
          PushErrorHandlerOp(targetPc: 11, errorVar: 'retry_error'), // 7
          DispatchParallelTasksOp(
            dispatches: [
              ParallelTaskDispatch(agentId: 'a', taskPrompt: 'task A', outputVar: 'out_a'),
              ParallelTaskDispatch(agentId: 'b', taskPrompt: 'task B', outputVar: 'out_b'),
            ],
          ), // 8
          PopErrorHandlerOp(), // 9
          JumpOp(targetPc: 14), // 10 success → end
          MarkEffectRetryOp(), // 11 catch
          IncrementRegisterOp(registerName: 'attempt'), // 12
          JumpOp(targetPc: 4), // 13 back-edge
          PopEffectScopeOp(), // 14 end
          HaltOp(), // 15
        ],
      );

      final state = await runtime.executeProgram(program);

      expect(state.status, RuntimeStatus.halted, reason: 'error: ${state.errorDetails}');
      expect(state.registers['out_a'], contains('A done'));
      expect(state.registers['out_b'], contains('B done'));
      expect(aRuns, 1, reason: 'A succeeded in attempt 1 — attempt 2 must replay it');
      expect(bRuns, 2, reason: 'B failed once, re-ran once');
      await vm.shutdown();
    });
  });

  group('agent-INTERNAL tool dedup (GAP-3a)', () {
    test('a re-dispatched task replays the tool its failed predecessor '
        'already executed', () async {
      var generateCalls = 0;
      var alertsSent = 0;

      final model = FakeVasterModel(
        handler: (request) {
          generateCalls++;
          switch (generateCalls) {
            case 1: // attempt 1, agent turn 1: call the tool
            case 3: // attempt 2 (re-dispatch), agent turn 1: same call
              return ModelResponse(
                message: ChatMessage(
                  role: Role.model,
                  parts: [
                    const TextPart('Alerting.'),
                    FunctionCallPart(
                      callId: 'c$generateCalls',
                      name: 'send_alert',
                      arguments: const {'msg': 'disk full'},
                    ),
                  ],
                ),
                finishReason: FinishReason.toolCalls,
              );
            case 2: // attempt 1: the agent's model dies AFTER the tool ran
              throw StateError('API error 500 mid-task');
            default: // attempt 2 continuation: success
              return ModelResponse(message: ChatMessage.model('delivered'));
          }
        },
      );

      final (vm, runtime) = await boot(model);
      vm.registerTool(
        FunctionTool.define(
          name: 'send_alert',
          description: 'Send an alert (non-compensable side effect)',
          parametersSchema: const {
            'type': 'object',
            'properties': {
              'msg': {'type': 'string'},
            },
          },
          handler: (args) {
            alertsSent++;
            return {'status': 'sent'};
          },
        ),
      );

      final replayed = <ToolCallReplayedEvent>[];
      final sub = vm.eventBus.on<ToolCallReplayedEvent>().listen(replayed.add);

      // Resilient loop around the DISPATCH: the task itself fails on
      // attempt 1 (so GAP-2 records nothing) and the re-dispatched
      // agent's first tool call must replay through its effect region.
      const program = VasterProgram(
        programName: 'agent_internal_dedup',
        instructions: [
          CreateAgentOp(
            descriptor: AgentDescriptor(
              agentId: 'notifier',
              name: 'Notifier',
              role: 'ops',
              systemInstruction: 'Notify.',
            ),
          ), // 0
          PushEffectScopeOp(), // 1
          SetRegisterOp(registerName: 'attempt', value: 0), // 2
          CompareRegisterOp(
            // 3 head
            leftVar: 'attempt',
            operator: 'lt',
            rightValue: 3,
            targetVar: 'cmp',
          ),
          JumpIfOp(conditionVar: 'cmp', targetPc: 6), // 4
          JumpOp(targetPc: 13), // 5 exhausted → end
          PushErrorHandlerOp(targetPc: 10, errorVar: 'retry_error'), // 6
          DispatchAgentTaskOp(
            agentId: 'notifier',
            taskPrompt: 'alert the operator',
            outputVar: 'result',
          ), // 7
          PopErrorHandlerOp(), // 8
          JumpOp(targetPc: 13), // 9 success → end
          MarkEffectRetryOp(), // 10 catch
          IncrementRegisterOp(registerName: 'attempt'), // 11
          JumpOp(targetPc: 3), // 12 back-edge
          PopEffectScopeOp(), // 13 end
          HaltOp(), // 14
        ],
      );

      final state = await runtime.executeProgram(program);
      await sub.cancel();

      expect(state.status, RuntimeStatus.halted, reason: 'error: ${state.errorDetails}');
      expect(state.registers['result'], contains('delivered'));
      expect(
        alertsSent,
        1,
        reason:
            'agent parity (GAP-3a): the re-dispatched task must '
            'replay the tool its failed predecessor executed',
      );
      expect(replayed, hasLength(1));
      expect(replayed.single.toolName, 'send_alert');
      await vm.shutdown();
    });
  });

  group('EffectLedger unit semantics', () {
    Future<Map<String, dynamic>> counted(List<int> counter, Map<String, dynamic> result) async {
      counter[0]++;
      return result;
    }

    // The claim→execute→commit protocol, test-local (the production
    // consumers — dispatch dedup and both tool loops — compose the same
    // primitives; the old executeOrReplay sugar had no production
    // callers and was deleted).
    Future<({Map<String, dynamic> result, bool replayed})> runThrough({
      required EffectLedger ledger,
      required String name,
      required Map<String, dynamic> arguments,
      required Future<Map<String, dynamic>> Function() execute,
    }) async {
      final slot = ledger.claim(name: name, arguments: arguments);
      final recorded = slot.recorded;
      if (recorded != null) return (result: recorded, replayed: true);
      final result = await execute();
      if (!result.containsKey('error')) ledger.commit(slot, result);
      return (result: result, replayed: false);
    }

    test('outside any scope, calls pass through with zero bookkeeping', () async {
      final ledger = EffectLedger();
      final calls = [0];
      for (var i = 0; i < 2; i++) {
        final outcome = await runThrough(
          ledger: ledger,
          name: 't',
          arguments: {'a': 1},
          execute: () => counted(calls, {'ok': true}),
        );
        expect(outcome.replayed, isFalse);
      }
      expect(calls[0], 2);
      expect(ledger.captureState(), isEmpty);
    });

    test('after markRetry, identical calls replay in occurrence order', () async {
      final ledger = EffectLedger()..pushScope(0);
      final calls = [0];

      // Attempt 1: the same call twice — both execute, occurrences 1 and 2.
      final first = await runThrough(
        ledger: ledger,
        name: 't',
        arguments: {'a': 1},
        execute: () => counted(calls, {'n': 1}),
      );
      final second = await runThrough(
        ledger: ledger,
        name: 't',
        arguments: {'a': 1},
        execute: () => counted(calls, {'n': 2}),
      );
      expect([first.replayed, second.replayed], [false, false]);
      expect(calls[0], 2);

      // Attempt 2 replays both, in order, without executing.
      ledger.markRetry();
      final r1 = await runThrough(
        ledger: ledger,
        name: 't',
        arguments: {'a': 1},
        execute: () => counted(calls, {'n': 99}),
      );
      final r2 = await runThrough(
        ledger: ledger,
        name: 't',
        arguments: {'a': 1},
        execute: () => counted(calls, {'n': 99}),
      );
      expect([r1.replayed, r2.replayed], [true, true]);
      expect([r1.result['n'], r2.result['n']], [1, 2]);
      expect(calls[0], 2, reason: 'no re-execution');
    });

    test('argument maps differing only in key order share one identity', () async {
      final ledger = EffectLedger()..pushScope(0);
      final calls = [0];
      await runThrough(
        ledger: ledger,
        name: 't',
        arguments: {'b': 2, 'a': 1},
        execute: () => counted(calls, {'ok': true}),
      );
      ledger.markRetry();
      final outcome = await runThrough(
        ledger: ledger,
        name: 't',
        arguments: {'a': 1, 'b': 2},
        execute: () => counted(calls, {'ok': true}),
      );
      expect(outcome.replayed, isTrue);
      expect(calls[0], 1);
    });

    test('error results are not recorded — the retry re-executes them', () async {
      final ledger = EffectLedger()..pushScope(0);
      final calls = [0];
      final failed = await runThrough(
        ledger: ledger,
        name: 't',
        arguments: {},
        execute: () => counted(calls, {'error': 'flaky'}),
      );
      expect(failed.replayed, isFalse);

      ledger.markRetry();
      final retried = await runThrough(
        ledger: ledger,
        name: 't',
        arguments: {},
        execute: () => counted(calls, {'ok': true}),
      );
      expect(retried.replayed, isFalse, reason: 'errors never dedupe');
      expect(calls[0], 2);
    });

    test('nested scopes: an outer retry replays the inner region\'s calls', () async {
      final ledger = EffectLedger()..pushScope(10); // outer Resilient
      final calls = [0];

      // Outer attempt 1: inner scope opens at pc 20, executes, pops.
      ledger.pushScope(20);
      await runThrough(
        ledger: ledger,
        name: 'inner_t',
        arguments: {'x': 1},
        execute: () => counted(calls, {'n': 1}),
      );
      ledger.popScope();
      expect(calls[0], 1);

      // Outer attempt fails; attempt 2 re-enters the inner region at the
      // same pc — its call must replay from attempt 1's record.
      ledger.markRetry();
      ledger.pushScope(20);
      final outcome = await runThrough(
        ledger: ledger,
        name: 'inner_t',
        arguments: {'x': 1},
        execute: () => counted(calls, {'n': 99}),
      );
      expect(outcome.replayed, isTrue);
      expect(outcome.result['n'], 1);
      expect(calls[0], 1);
    });

    test('closing the outermost scope drops the store', () async {
      final ledger = EffectLedger()..pushScope(0);
      await runThrough(ledger: ledger, name: 't', arguments: {}, execute: () async => {'ok': true});
      ledger.popScope();
      expect(ledger.captureState(), isEmpty, reason: 'a completed retry region leaves no history behind');
    });

    test('capture/restore keeps dedup memory across a checkpoint (Rule 8)', () async {
      final ledger = EffectLedger()..pushScope(5);
      final calls = [0];
      await runThrough(
        ledger: ledger,
        name: 't',
        arguments: {'k': 'v'},
        execute: () => counted(calls, {'n': 7}),
      );

      final restored = EffectLedger()..restoreState(ledger.captureState());
      restored.markRetry();
      final outcome = await runThrough(
        ledger: restored,
        name: 't',
        arguments: {'k': 'v'},
        execute: () => counted(calls, {'n': 99}),
      );
      expect(outcome.replayed, isTrue);
      expect(outcome.result['n'], 7);
      expect(calls[0], 1);
      expect(restored.depth, 1);
    });

    test('unwindTo closes abandoned scopes but keeps enclosed records', () async {
      final ledger = EffectLedger()..pushScope(1);
      ledger.pushScope(2);
      ledger.pushScope(3);
      ledger.unwindTo(1);
      expect(ledger.depth, 1);
      ledger.unwindTo(0);
      expect(ledger.depth, 0);
      expect(ledger.captureState(), isEmpty);
    });
  });

  group('EffectKey grammar (A6)', () {
    test('separator characters inside args, names, and scopes cannot '
        'collide keys — the grammar is self-delimiting', () async {
      final ledger = EffectLedger()..pushScope(0);
      // Two calls crafted so the OLD concatenation grammar
      // (scope#name|args|occ) would have produced identical keys.
      final a = ledger.claim(
          name: 'x|y', arguments: {'k': 'v'}, scope: 'r');
      final b = ledger.claim(
          name: 'y', arguments: {'k': 'v'}, scope: 'r#x|');
      expect(a, isA<Object>());
      expect((a as dynamic).slotId, isNot((b as dynamic).slotId),
          reason: 'JSON-array keys cannot be confused by separators '
              'inside their segments');
    });

    test('policy telemetry ids are deterministic sequences, engine ids '
        'carry the machine-state sequence (A5)', () async {
      final (vm, runtime) = await boot(FakeVasterModel());
      final warnings = <RuntimeWarningEvent>[];
      final sub = vm.eventBus.on<RuntimeWarningEvent>().listen(warnings.add);
      const program = VasterProgram(
        programName: 'seq_ids',
        instructions: [CommitOp(), CommitOp(), HaltOp()],
      );
      await runtime.executeProgram(program);
      await sub.cancel();
      final ids = warnings.map((w) => w.eventId).toList();
      expect(ids.toSet().length, ids.length,
          reason: 'same-pc same-kind events must not collide (A5)');
      await vm.shutdown();
    });
  });
}
