import 'dart:convert';

import 'package:test/test.dart';
import 'package:vaster_model_fake/vaster_model_fake.dart';
import 'package:vaster_vm/vaster_vm.dart';

/// ISA-level DecideOp coverage with hand-built programs (runtime packages
/// never touch the compiler frontend). Compiled Decide/DecideLoop coverage
/// lives in vaster_playground.
void main() {
  group('DecideOp — model-steered branching', () {
    // Layout used by most tests:
    //   0: decide {left -> 2, right -> 4} out=choice
    //   1: halt                          (unreachable)
    //   2: took_left = true
    //   3: halt
    //   4: took_right = true
    //   5: halt
    VasterProgram program({String? outputVar = 'choice', String? defaultLabel}) =>
        VasterProgram(programName: 'decide_demo', instructions: [
          DecideOp(
            prompt: 'Left or right?',
            branches: const [
              DecisionBranch(label: 'left', description: 'go left', targetPc: 2),
              DecisionBranch(label: 'right', description: 'go right', targetPc: 4),
            ],
            outputVar: outputVar,
            defaultLabel: defaultLabel,
          ),
          const HaltOp(),
          const SetRegisterOp(registerName: 'took_left', value: true),
          const HaltOp(),
          const SetRegisterOp(registerName: 'took_right', value: true),
          const HaltOp(),
        ]);

    Future<(VasterVirtualMachine, VasterRuntime)> boot(FakeVasterModel model) async {
      final vm = await VasterVMEngine.bootstrap(config: VMConfig(defaultModel: model));
      final runtime = VasterRuntime(
        vm: vm,
        policy: ExecutionPolicy.unlimited,
        budget: ExecutionBudget.unlimited(),
        scheduler: BasicVasterScheduler(taskQueue: PriorityTaskQueue()),
      );
      return (vm, runtime);
    }

    test('model choice steers control flow; label and rationale land in registers',
        () async {
      final model = FakeVasterModel(handler: (request) {
        // The decision request carries the enum-constrained schema.
        final schema = request.generationConfig.responseSchema!;
        expect(
            (schema['properties'] as Map)['choice']['enum'], equals(['left', 'right']));
        return ModelResponse(
          message: ChatMessage.model(
              jsonEncode({'choice': 'right', 'rationale': 'the right is clear'})),
        );
      });
      final (vm, runtime) = await boot(model);

      final state = await runtime.executeProgram(program());

      expect(state.status, RuntimeStatus.halted);
      expect(state.registers['took_right'], isTrue);
      expect(state.registers['took_left'], isNull);
      expect(state.registers['choice'], equals('right'));
      expect(state.registers['choice_rationale'], equals('the right is clear'));
      await vm.shutdown();
    });

    test('markdown-fenced JSON answers parse', () async {
      final model = FakeVasterModel(handler: (_) {
        return ModelResponse(
          message: ChatMessage.model('```json\n{"choice": "left"}\n```'),
        );
      });
      final (vm, runtime) = await boot(model);

      final state = await runtime.executeProgram(program());
      expect(state.registers['took_left'], isTrue);
      await vm.shutdown();
    });

    test('bare-label answers parse case-insensitively', () async {
      final model = FakeVasterModel(handler: (_) {
        return ModelResponse(message: ChatMessage.model('  Left \n'));
      });
      final (vm, runtime) = await boot(model);

      final state = await runtime.executeProgram(program());
      expect(state.registers['took_left'], isTrue);
      expect(state.registers['choice'], equals('left'),
          reason: 'the canonical label is written, not the raw answer');
      await vm.shutdown();
    });

    test('unresolvable answer takes the default branch and flags the event',
        () async {
      final events = <DecisionMadeEvent>[];
      final model = FakeVasterModel(handler: (_) {
        return ModelResponse(message: ChatMessage.model('up? maybe down?'));
      });
      final (vm, runtime) = await boot(model);
      vm.eventBus.on<DecisionMadeEvent>().listen(events.add);

      final state = await runtime.executeProgram(program(defaultLabel: 'right'));
      await Future<void>.delayed(Duration.zero);

      expect(state.registers['took_right'], isTrue);
      expect(events.single.usedDefault, isTrue);
      expect(events.single.chosenLabel, equals('right'));
      await vm.shutdown();
    });

    test('unresolvable answer with no default traps the VM', () async {
      final model = FakeVasterModel(handler: (_) {
        return ModelResponse(message: ChatMessage.model('neither'));
      });
      final (vm, runtime) = await boot(model);

      final state = await runtime.executeProgram(program());
      expect(state.status, RuntimeStatus.error);
      expect(state.errorDetails, contains('VASTER VM TRAP'));
      expect(state.errorDetails, contains('left, right'),
          reason: 'the trap names the available branch labels');
      await vm.shutdown();
    });

    test('a failed decision is catchable by a program-level error handler',
        () async {
      final model = FakeVasterModel(handler: (_) {
        return ModelResponse(message: ChatMessage.model('nonsense'));
      });
      final (vm, runtime) = await boot(model);

      // 0: pushErrorHandler -> 3   1: decide (fails)  2: halt
      // 3: recovered = true        4: halt
      final state = await runtime.executeProgram(const VasterProgram(
        programName: 'decide_catch',
        instructions: [
          PushErrorHandlerOp(targetPc: 3, errorVar: 'err'),
          DecideOp(prompt: 'choose', branches: [
            DecisionBranch(label: 'only', description: 'the one', targetPc: 2),
          ]),
          HaltOp(),
          SetRegisterOp(registerName: 'recovered', value: true),
          HaltOp(),
        ],
      ));

      expect(state.status, RuntimeStatus.halted);
      expect(state.registers['recovered'], isTrue);
      expect('${state.registers['err']}', contains('resolved to no branch'));
      expect('${state.registers['err']}', contains('nonsense'),
          reason: 'DecisionUnresolved carries the raw model answer into the '
              'trap — the error says WHAT the model said, not just that it '
              'failed');
      await vm.shutdown();
    });

    test('empty branch list traps immediately', () async {
      final model = FakeVasterModel();
      final (vm, runtime) = await boot(model);

      final state = await runtime.executeProgram(const VasterProgram(
        programName: 'decide_empty',
        instructions: [DecideOp(prompt: 'p', branches: []), HaltOp()],
      ));
      expect(state.status, RuntimeStatus.error);
      expect(state.errorDetails, contains('no branches'));
      expect(model.recordedRequests, isEmpty,
          reason: 'no model call is made for a malformed decide');
      await vm.shutdown();
    });

    test('decision consumes budget and publishes DecisionMadeEvent', () async {
      final events = <DecisionMadeEvent>[];
      final model = FakeVasterModel(handler: (_) {
        return ModelResponse(
          message: ChatMessage.model(jsonEncode({'choice': 'left'})),
        );
      });
      final vm = await VasterVMEngine.bootstrap(config: VMConfig(defaultModel: model));
      vm.eventBus.on<DecisionMadeEvent>().listen(events.add);
      final budget = ExecutionBudget.unlimited();
      final runtime = VasterRuntime(
        vm: vm,
        policy: ExecutionPolicy.unlimited,
        budget: budget,
        scheduler: BasicVasterScheduler(taskQueue: PriorityTaskQueue()),
      );

      await runtime.executeProgram(program());
      await Future<void>.delayed(Duration.zero);

      expect(budget.consumedTokens, greaterThan(0));
      expect(events.single.chosenLabel, equals('left'));
      expect(events.single.branchCount, equals(2));
      expect(events.single.targetPc, equals(2));
      expect(events.single.usedDefault, isFalse);
      await vm.shutdown();
    });

    test('session-routed decision appends to conversational history', () async {
      final model = FakeVasterModel(handler: (_) {
        return ModelResponse(
          message: ChatMessage.model(jsonEncode({'choice': 'left'})),
        );
      });
      final (vm, runtime) = await boot(model);

      // Note: branch targets are absolute PCs — the session ops shift the
      // layout, so this program is laid out independently of program().
      final state = await runtime.executeProgram(const VasterProgram(
        programName: 'decide_session',
        instructions: [
          CreateSessionOp(sessionId: 'sess_decide'),
          SetSessionOp(sessionId: 'sess_decide'),
          DecideOp(
            prompt: 'Left or right?',
            branches: [
              DecisionBranch(label: 'left', description: 'go left', targetPc: 4),
              DecisionBranch(label: 'right', description: 'go right', targetPc: 6),
            ],
            outputVar: 'choice',
          ),
          HaltOp(),
          SetRegisterOp(registerName: 'took_left', value: true),
          HaltOp(),
          SetRegisterOp(registerName: 'took_right', value: true),
          HaltOp(),
        ],
      ));

      expect(state.status, RuntimeStatus.halted);
      final history = vm.sessionManager.getSession('sess_decide')!.history;
      expect(history.first.text, contains('Left or right?'),
          reason: 'the decision turn is part of the session memory');
      expect(history.first.text, contains('- left: go left'),
          reason: 'the branch menu is presented to the model');
      await vm.shutdown();
    });

    test('a response carrying functionCalls still decides from its text',
        () async {
      final model = FakeVasterModel(handler: (_) {
        return ModelResponse(
          message: ChatMessage(role: Role.model, parts: [
            TextPart(jsonEncode({'choice': 'right'})),
            const FunctionCallPart(callId: 'c1', name: 'noise', arguments: {}),
          ]),
          finishReason: FinishReason.toolCalls,
        );
      });
      final (vm, runtime) = await boot(model);

      final state = await runtime.executeProgram(program());
      expect(state.registers['took_right'], isTrue,
          reason: 'decisions are atomic — no tool loop runs');
      expect(model.recordedRequests, hasLength(1),
          reason: 'exactly one model call, no tool continuation');
      await vm.shutdown();
    });
  });
}
