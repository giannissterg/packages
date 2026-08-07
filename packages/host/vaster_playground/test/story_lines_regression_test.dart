import 'dart:io';

import 'package:test/test.dart';
import 'package:vaster_replay/vaster_replay.dart';
import 'package:vaster_vm/vaster_vm.dart';

/// **The agent-regression pattern, as a committed test** — copy this
/// file into your own project (docs/AGENT_TESTING.md is the walkthrough).
///
/// The fixture was recorded ONCE on a real local model
/// (`vaster run … --record`). This test re-executes the pipeline against
/// the tape on every CI run: zero tokens, zero network, and it fails the
/// moment ANY change — prompt template, compiler output, context
/// compilation, runtime dispatch — alters what the pipeline asks a model.
/// When it fails, `vaster replay <fixture> --diff` says exactly what
/// changed, down to the character.
void main() {
  test('story_lines behaves exactly as recorded (agent regression)', () async {
    final envelope = const ReplayEnvelopeCodec().decodeString(
      File('test/fixtures/story_lines_v2.replay.json').readAsStringSync(),
    );
    final program = VasterProgram.fromJson(envelope.programJson!);

    final replayModel = ReplayVasterModel(tape: envelope.tape);
    final vm = await VasterVMEngine.bootstrap(config: VMConfig(defaultModel: replayModel));
    addTearDown(vm.shutdown);
    final runtime = VasterRuntime(
      vm: vm,
      policy: ExecutionPolicy.unlimited,
      budget: ExecutionBudget.unlimited(),
      scheduler: BasicVasterScheduler(taskQueue: PriorityTaskQueue()),
    );

    final state = await runtime.executeProgram(program);

    expect(
      replayModel.lastDivergence,
      isNull,
      reason:
          'a request the tape does not hold means behavior changed — '
          'run `vaster replay <fixture> --diff` for the char-located '
          'report',
    );
    expect(state.status, RuntimeStatus.halted);
    expect(
      replayModel.remaining,
      0,
      reason:
          'unconsumed recordings mean the pipeline now makes fewer '
          'or different calls — also a behavior change',
    );
    expect(
      state.registers[program.resultBinding],
      isNotNull,
      reason: 'the declared result materialized from replayed calls',
    );
  });
}
