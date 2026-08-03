import 'package:test/test.dart';
import 'package:vaster_domain/vaster_domain.dart';
import 'package:vaster_model_fake/vaster_model_fake.dart';
import 'package:vaster_vm/vaster_vm.dart';

void main() {
  group('Multi-Pipeline VM Scheduler Composition Tests', () {
    late VasterVirtualMachine vm;

    setUp(() async {
      final fakeModel = FakeVasterModel();
      vm = await VasterVMEngine.bootstrap(config: VMConfig(defaultModel: fakeModel));
    });

    tearDown(() async {
      await vm.shutdown();
    });

    test('submits and time-slices execution across multiple AST programs concurrently', () async {
      final program1 = VasterProgram(
        programName: 'pipeline_alpha',
        instructions: const [
          WriteFileOp(vfsPath: '/mem/alpha.txt', content: 'Alpha Output'),
          PromptOp(promptText: 'Alpha turn'),
          HaltOp(),
        ],
      );

      final program2 = VasterProgram(
        programName: 'pipeline_beta',
        instructions: const [
          WriteFileOp(vfsPath: '/mem/beta.txt', content: 'Beta Output'),
          PromptOp(promptText: 'Beta turn'),
          HaltOp(),
        ],
      );

      // Submit both programs with different priorities
      final job1 = vm.submitProgram(program1, priority: TaskPriority.high);
      final job2 = vm.submitProgram(program2, priority: TaskPriority.normal);

      expect(job1.isDone, isFalse);
      expect(job2.isDone, isFalse);

      // Run multi-pipeline scheduled jobs
      final results = await vm.runScheduledJobs(stepQuantum: 2);

      expect(results.containsKey(job1.jobId), isTrue);
      expect(results.containsKey(job2.jobId), isTrue);
      expect(results[job1.jobId]!.status, equals(RuntimeStatus.halted));
      expect(results[job2.jobId]!.status, equals(RuntimeStatus.halted));

      // Verify filesystem outputs from both pipelines
      final alphaContent = await vm.fileSystemManager
          .resolveFileSystem('/mem/alpha.txt')
          .readText('/mem/alpha.txt');
      final betaContent = await vm.fileSystemManager
          .resolveFileSystem('/mem/beta.txt')
          .readText('/mem/beta.txt');

      expect(alphaContent, equals('Alpha Output'));
      expect(betaContent, equals('Beta Output'));
    });

    test('quanta run through the scheduler state machine, not around it', () async {
      final program = VasterProgram(
        programName: 'lifecycle',
        instructions: const [
          SetRegisterOp(registerName: 'a', value: 1),
          SetRegisterOp(registerName: 'b', value: 2),
          SetRegisterOp(registerName: 'c', value: 3),
          HaltOp(),
        ],
      );

      final job = vm.submitProgram(program);

      // The submitted quantum sits in the queue in the `queued` state and its
      // completer resolves with the quantum's RuntimeState once dispatched.
      final firstQuantum = vm.scheduler.taskQueue.peek()!;
      expect(firstQuantum.state, equals(ExecutionState.queued));

      final results = await vm.runScheduledJobs(stepQuantum: 2);

      // runNext drove the task through running → completed and resolved its
      // completer — the state machine the old direct-dispatch path bypassed.
      expect(firstQuantum.state, equals(ExecutionState.completed));
      final firstState = await firstQuantum.completer.future as RuntimeState;
      expect(firstState.status, equals(RuntimeStatus.running),
          reason: 'a 2-instruction quantum of a 4-instruction program '
              'retires with the machine still running');

      expect(results[job.jobId]!.status, equals(RuntimeStatus.halted));
      expect(job.lastState.registers['c'], equals(3));
      expect(vm.scheduler.taskQueue.isEmpty, isTrue,
          reason: 'no orphaned quanta after the job halts');
    });

    test('a job whose budget is exhausted lands as timedOut, not stranded', () async {
      final program = VasterProgram(
        programName: 'starved',
        instructions: const [
          SetRegisterOp(registerName: 'x', value: 1),
          HaltOp(),
        ],
      );

      final job = vm.submitProgram(
        program,
        customBudget: ExecutionBudget(maxTokens: 0),
      );

      final results = await vm.runScheduledJobs();

      expect(results[job.jobId]!.status, equals(RuntimeStatus.timedOut));
      expect(job.isDone, isTrue,
          reason: 'budget expiry at dispatch must terminate the job');
    });

    test('a HITL pause parks the job without re-enqueueing quanta', () async {
      final program = VasterProgram(
        programName: 'parked',
        instructions: const [
          YieldHumanInteractionOp(
            request: HumanInteractionRequest(
              requestId: 'req_park',
              type: HumanInteractionType.approval,
              prompt: 'Proceed?',
              options: ['approve', 'reject'],
              outputVar: 'answer',
            ),
          ),
          HaltOp(),
        ],
      );

      final job = vm.submitProgram(program);
      final results = await vm.runScheduledJobs();

      expect(results[job.jobId]!.status, equals(RuntimeStatus.pausedForHuman));
      expect(job.isPausedForHuman, isTrue);
      expect(vm.scheduler.taskQueue.isEmpty, isTrue,
          reason: 'a parked job must not spin in the run queue');
    });
  });
}
