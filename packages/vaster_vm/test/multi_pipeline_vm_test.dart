import 'package:test/test.dart';
import 'package:vaster_instruction/vaster_instruction.dart';
import 'package:vaster_model_fake/vaster_model_fake.dart';
import 'package:vaster_runtime/vaster_runtime.dart';
import 'package:vaster_scheduler/vaster_scheduler.dart';
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
  });
}
