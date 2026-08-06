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
        config: VMConfig(defaultModel: model, rootMountPath: '/mem'));
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
      expect(state.registers['observed'], 'v1',
          reason: 'the abandoned transaction\'s partial write must be gone '
              'by the time the handler observes the file — this used to '
              'leak v2_partial');
      expect(vm.fileSystemManager.transactionDepth, 0,
          reason: 'no abandoned open transaction survives the catch');
      await vm.shutdown();
    });
  });

  group('effect scopes — idempotency at the tool boundary', () {
    test('a retried attempt replays the executed tool call instead of '
        're-performing the side effect', () async {
      var generateCalls = 0;
      var alertsSent = 0;

      final model = FakeVasterModel(handler: (request) {
        generateCalls++;
        switch (generateCalls) {
          case 1: // attempt 1: ask for the tool
          case 3: // attempt 2: ask for the SAME tool call again
            return ModelResponse(
              message: ChatMessage(role: Role.model, parts: [
                const TextPart('Sending the alert.'),
                FunctionCallPart(
                  callId: 'call_$generateCalls',
                  name: 'send_alert',
                  arguments: const {'message': 'deploy failed'},
                ),
              ]),
              finishReason: FinishReason.toolCalls,
            );
          case 2: // attempt 1 continuation: model dies AFTER the tool ran
            throw StateError('API error 500 mid-turn');
          default: // attempt 2 continuation: success
            return ModelResponse(
                message: ChatMessage.model('alert delivered'));
        }
      });

      final (vm, runtime) = await boot(model);
      vm.registerTool(FunctionTool.define(
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
      ));

      final replayed = <ToolCallReplayedEvent>[];
      final sub =
          vm.eventBus.on<ToolCallReplayedEvent>().listen(replayed.add);

      // The canonical Resilient shape, hand-assembled, with its REL-P4
      // effect-scope brackets.
      const program = VasterProgram(
        programName: 'retry_dedup',
        instructions: [
          PushEffectScopeOp(), // 0
          SetRegisterOp(registerName: 'attempt', value: 0), // 1
          CompareRegisterOp( // 2 head
              leftVar: 'attempt',
              operator: 'lt',
              rightValue: 3,
              targetVar: 'cmp'),
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
      expect(state.registers['attempt'], 1,
          reason: 'attempt 1 failed, attempt 2 succeeded');
      expect(alertsSent, 1,
          reason: 'THE claim of REL-P4: the retried turn must not send the '
              'alert twice');
      expect(replayed, hasLength(1));
      expect(replayed.single.toolName, 'send_alert');
      await vm.shutdown();
    });
  });

  group('EffectLedger unit semantics', () {
    Future<Map<String, dynamic>> counted(
        List<int> counter, Map<String, dynamic> result) async {
      counter[0]++;
      return result;
    }

    test('outside any scope, calls pass through with zero bookkeeping',
        () async {
      final ledger = EffectLedger();
      final calls = [0];
      for (var i = 0; i < 2; i++) {
        final outcome = await ledger.executeOrReplay(
            name: 't',
            arguments: {'a': 1},
            execute: () => counted(calls, {'ok': true}));
        expect(outcome.replayed, isFalse);
      }
      expect(calls[0], 2);
      expect(ledger.captureState(), isEmpty);
    });

    test('after markRetry, identical calls replay in occurrence order',
        () async {
      final ledger = EffectLedger()..pushScope(0);
      final calls = [0];

      // Attempt 1: the same call twice — both execute, occurrences 1 and 2.
      final first = await ledger.executeOrReplay(
          name: 't', arguments: {'a': 1}, execute: () => counted(calls, {'n': 1}));
      final second = await ledger.executeOrReplay(
          name: 't', arguments: {'a': 1}, execute: () => counted(calls, {'n': 2}));
      expect([first.replayed, second.replayed], [false, false]);
      expect(calls[0], 2);

      // Attempt 2 replays both, in order, without executing.
      ledger.markRetry();
      final r1 = await ledger.executeOrReplay(
          name: 't', arguments: {'a': 1}, execute: () => counted(calls, {'n': 99}));
      final r2 = await ledger.executeOrReplay(
          name: 't', arguments: {'a': 1}, execute: () => counted(calls, {'n': 99}));
      expect([r1.replayed, r2.replayed], [true, true]);
      expect([r1.result['n'], r2.result['n']], [1, 2]);
      expect(calls[0], 2, reason: 'no re-execution');
    });

    test('argument maps differing only in key order share one identity',
        () async {
      final ledger = EffectLedger()..pushScope(0);
      final calls = [0];
      await ledger.executeOrReplay(
          name: 't',
          arguments: {'b': 2, 'a': 1},
          execute: () => counted(calls, {'ok': true}));
      ledger.markRetry();
      final outcome = await ledger.executeOrReplay(
          name: 't',
          arguments: {'a': 1, 'b': 2},
          execute: () => counted(calls, {'ok': true}));
      expect(outcome.replayed, isTrue);
      expect(calls[0], 1);
    });

    test('error results are not recorded — the retry re-executes them',
        () async {
      final ledger = EffectLedger()..pushScope(0);
      final calls = [0];
      final failed = await ledger.executeOrReplay(
          name: 't',
          arguments: {},
          execute: () => counted(calls, {'error': 'flaky'}));
      expect(failed.replayed, isFalse);

      ledger.markRetry();
      final retried = await ledger.executeOrReplay(
          name: 't', arguments: {}, execute: () => counted(calls, {'ok': true}));
      expect(retried.replayed, isFalse, reason: 'errors never dedupe');
      expect(calls[0], 2);
    });

    test('nested scopes: an outer retry replays the inner region\'s calls',
        () async {
      final ledger = EffectLedger()..pushScope(10); // outer Resilient
      final calls = [0];

      // Outer attempt 1: inner scope opens at pc 20, executes, pops.
      ledger.pushScope(20);
      await ledger.executeOrReplay(
          name: 'inner_t',
          arguments: {'x': 1},
          execute: () => counted(calls, {'n': 1}));
      ledger.popScope();
      expect(calls[0], 1);

      // Outer attempt fails; attempt 2 re-enters the inner region at the
      // same pc — its call must replay from attempt 1's record.
      ledger.markRetry();
      ledger.pushScope(20);
      final outcome = await ledger.executeOrReplay(
          name: 'inner_t',
          arguments: {'x': 1},
          execute: () => counted(calls, {'n': 99}));
      expect(outcome.replayed, isTrue);
      expect(outcome.result['n'], 1);
      expect(calls[0], 1);
    });

    test('closing the outermost scope drops the store', () async {
      final ledger = EffectLedger()..pushScope(0);
      await ledger.executeOrReplay(
          name: 't', arguments: {}, execute: () async => {'ok': true});
      ledger.popScope();
      expect(ledger.captureState(), isEmpty,
          reason: 'a completed retry region leaves no history behind');
    });

    test('capture/restore keeps dedup memory across a checkpoint (Rule 8)',
        () async {
      final ledger = EffectLedger()..pushScope(5);
      final calls = [0];
      await ledger.executeOrReplay(
          name: 't', arguments: {'k': 'v'}, execute: () => counted(calls, {'n': 7}));

      final restored = EffectLedger()..restoreState(ledger.captureState());
      restored.markRetry();
      final outcome = await restored.executeOrReplay(
          name: 't', arguments: {'k': 'v'}, execute: () => counted(calls, {'n': 99}));
      expect(outcome.replayed, isTrue);
      expect(outcome.result['n'], 7);
      expect(calls[0], 1);
      expect(restored.depth, 1);
    });

    test('unwindTo closes abandoned scopes but keeps enclosed records',
        () async {
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
}
