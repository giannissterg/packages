import 'dart:io';

import 'package:test/test.dart';
import 'package:vaster_continuation/vaster_continuation.dart';
import 'package:vaster_continuation_manager/vaster_continuation_manager.dart';
import 'package:vaster_model_fake/vaster_model_fake.dart';
import 'package:vaster_vm/vaster_vm.dart';

void main() {
  group('MemoryContinuationStore', () {
    test('saves, loads, lists, deletes, and clears continuations', () async {
      final store = MemoryContinuationStore();
      final continuation = VasterContinuation(
        continuationId: 'cont_mem_1',
        programName: 'mem_prog',
        resumePc: 10,
        registers: {'var': 'val'},
      );

      await store.saveContinuation(continuation);

      final loaded = await store.loadContinuation('cont_mem_1');
      expect(loaded, isNotNull);
      expect(loaded!.programName, equals('mem_prog'));
      expect(loaded.resumePc, equals(10));

      final list = await store.listContinuations();
      expect(list, hasLength(1));

      final deleted = await store.deleteContinuation('cont_mem_1');
      expect(deleted, isTrue);
      expect(await store.loadContinuation('cont_mem_1'), isNull);

      await store.saveContinuation(continuation);
      await store.clear();
      expect(await store.listContinuations(), isEmpty);
    });
  });

  group('FileContinuationStore', () {
    late Directory tempDir;
    late FileContinuationStore store;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('vaster_cont_store_test_');
      store = FileContinuationStore(storageDirectory: tempDir);
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('persists snapshots as JSON files on disk and restores correctly', () async {
      final snapshot = VasterContinuation(
        continuationId: 'cont_file_1',
        programName: 'disk_program',
        sessionId: 'sess_disk',
        resumePc: 42,
        registers: {'result': 'success_from_disk'},
        pendingRequest: const HumanInteractionRequest(
          requestId: 'req_disk_1',
          type: HumanInteractionType.approval,
          prompt: 'Approve disk deployment?',
        ),
      );

      await store.saveContinuation(snapshot);

      // Verify file exists on disk
      final jsonFile = File('${tempDir.path}/cont_file_1.json');
      expect(await jsonFile.exists(), isTrue);

      final loaded = await store.loadContinuation('cont_file_1');
      expect(loaded, isNotNull);
      expect(loaded!.continuationId, equals('cont_file_1'));
      expect(loaded.programName, equals('disk_program'));
      expect(loaded.sessionId, equals('sess_disk'));
      expect(loaded.resumePc, equals(42));
      expect(loaded.registers['result'], equals('success_from_disk'));
      expect(loaded.pendingRequest?.requestId, equals('req_disk_1'));

      final list = await store.listContinuations();
      expect(list, hasLength(1));

      final deleted = await store.deleteContinuation('cont_file_1');
      expect(deleted, isTrue);
      expect(await jsonFile.exists(), isFalse);
    });
  });

  group('BasicContinuationManager', () {
    late Directory tempDir;
    late VasterVMEngine vm;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('vaster_cont_mgr_test_');
      vm = await VasterVMEngine.bootstrap(
        config: VMConfig(defaultModel: FakeVasterModel()),
      );
    });

    tearDown(() async {
      await vm.shutdown();
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('captures snapshot into durable FileContinuationStore and restores runtime execution', () async {
      final store = FileContinuationStore(storageDirectory: tempDir);
      final manager = BasicContinuationManager(store: store);

      const program = VasterProgram(
        programName: 'durable_continuation_pipeline',
        instructions: [
          YieldHumanInteractionOp(
            request: HumanInteractionRequest(
              requestId: 'durable_req_1',
              type: HumanInteractionType.approval,
              prompt: 'Durable approval gate',
            ),
          ),
          SetRegisterOp(registerName: 'after_restore', value: 'resumed_durable'),
          HaltOp(),
        ],
      );

      // 1. Initial run on Server Instance #1 yields at HITL
      final runtime1 = VasterRuntime(
        vm: vm,
        policy: ExecutionPolicy.unlimited,
        budget: ExecutionBudget.unlimited(),
        scheduler: BasicVasterScheduler(taskQueue: PriorityTaskQueue()),
      );
      final state1 = await runtime1.executeProgram(program);
      expect(state1.status, equals(RuntimeStatus.pausedForHuman));

      // 2. Capture continuation snapshot into durable file store
      final captured = await manager.capture(runtime1, program.programName);
      expect(captured.resumePc, equals(0));

      final storedList = await manager.listContinuations();
      expect(storedList, hasLength(1));

      // 3. Simulate process restart: create fresh manager pointing to same disk store
      final manager2 = BasicContinuationManager(
        store: FileContinuationStore(storageDirectory: tempDir),
      );
      final restoredSnapshot = await manager2.getContinuation(captured.continuationId);
      expect(restoredSnapshot, isNotNull);

      // 4. Restore execution on fresh runtime instance #2
      final runtime2 = VasterRuntime(
        vm: vm,
        policy: ExecutionPolicy.unlimited,
        budget: ExecutionBudget.unlimited(),
        scheduler: BasicVasterScheduler(taskQueue: PriorityTaskQueue()),
      );
      final resumedState = await manager2.restoreAndResume(
        runtime2,
        restoredSnapshot!,
        program,
        humanResponse: HumanInteractionResponse.approve(
          requestId: 'durable_req_1',
          comment: 'Durable approval',
        ),
      );

      expect(resumedState.status, equals(RuntimeStatus.halted));
      expect(resumedState.registers['after_restore'], equals('resumed_durable'));
    });

    test('HITL pause inside a subroutine restores the call stack and returns through it', () async {
      final store = FileContinuationStore(storageDirectory: tempDir);
      final manager = BasicContinuationManager(store: store);

      // main:                          subroutine 'audited_step':
      //   0: call audited_step @3        3: yield (HITL approval gate)
      //   1: main_after = 'returned'     4: sub_result = 'approved_by_human'
      //   2: halt                        5: return sub_result -> verdict
      const program = VasterProgram(
        programName: 'subroutine_hitl',
        instructions: [
          CallOp(functionName: 'audited_step', targetPc: 3, outputVar: 'verdict'),
          SetRegisterOp(registerName: 'main_after', value: 'returned'),
          HaltOp(),
          YieldHumanInteractionOp(
            request: HumanInteractionRequest(
              requestId: 'sub_req',
              type: HumanInteractionType.approval,
              prompt: 'Approve the audited step?',
            ),
          ),
          SetRegisterOp(registerName: 'sub_result', value: 'approved_by_human'),
          ReturnSubroutineOp(returnRegister: 'sub_result'),
        ],
      );

      final runtime1 = VasterRuntime(
        vm: vm,
        policy: ExecutionPolicy.unlimited,
        budget: ExecutionBudget.unlimited(),
        scheduler: BasicVasterScheduler(taskQueue: PriorityTaskQueue()),
      );
      final paused = await runtime1.executeProgram(program);
      expect(paused.status, equals(RuntimeStatus.pausedForHuman));
      expect(paused.pc, equals(3), reason: 'suspended inside the subroutine');

      // The captured snapshot carries the activation record.
      final captured = await manager.capture(runtime1, program.programName);
      expect(captured.callStack, hasLength(1));
      expect(captured.callStack.single.functionName, equals('audited_step'));
      expect(captured.callStack.single.returnPc, equals(1));
      expect(captured.callStack.single.outputVar, equals('verdict'));

      // Process restart: reload from disk (full JSON round-trip) onto a fresh
      // runtime whose call stack starts empty.
      final manager2 = BasicContinuationManager(
        store: FileContinuationStore(storageDirectory: tempDir),
      );
      final reloaded = await manager2.getContinuation(captured.continuationId);
      expect(reloaded!.callStack.single.outputVar, equals('verdict'),
          reason: 'activation record survives serialization');

      final runtime2 = VasterRuntime(
        vm: vm,
        policy: ExecutionPolicy.unlimited,
        budget: ExecutionBudget.unlimited(),
        scheduler: BasicVasterScheduler(taskQueue: PriorityTaskQueue()),
      );
      final resumed = await manager2.restoreAndResume(
        runtime2,
        reloaded,
        program,
        humanResponse: HumanInteractionResponse.approve(requestId: 'sub_req'),
      );

      // The subroutine finished AND control returned through the restored
      // frame: the return value landed in the caller's output register and
      // the instruction after the call site executed.
      expect(resumed.status, equals(RuntimeStatus.halted));
      expect(resumed.registers['verdict'], equals('approved_by_human'));
      expect(resumed.registers['main_after'], equals('returned'));
    });
  });
}
