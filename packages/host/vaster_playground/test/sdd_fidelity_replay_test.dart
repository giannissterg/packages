import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:vaster_ast/vaster_ast.dart';
import 'package:vaster_compiler/vaster_compiler.dart';
import 'package:vaster_domain/vaster_domain.dart';
import 'package:vaster_replay/vaster_replay.dart';
import 'package:vaster_vm/vaster_vm.dart';

/// Zero-cost regression lock on the whole pipeline: compiler → prompts →
/// usage accounting → cost, verified against a REAL recorded claude-cli run
/// (2026-08-05: 438,700 prompt tokens, 87.9% cache reads, $0.825917 wire
/// cost). A replay miss means the frontend no longer lowers to the prompts
/// the model actually saw; a changed total means usage accounting drifted.
void main() {
  test('recorded real-model SDD run replays with exact usage and cost',
      () async {
    const architect = AgentRole(
        roleId: 'architect',
        name: 'Architect',
        title: 'Principal Architect',
        instruction: 'You write precise, reviewable specifications.');
    const lead = AgentRole(
        roleId: 'lead',
        name: 'Lead',
        title: 'Tech Lead',
        instruction: 'You turn specs into concrete implementation plans.');
    const reviewer = AgentRole(
        roleId: 'reviewer',
        name: 'Reviewer',
        title: 'Staff Reviewer',
        instruction: 'You review artifacts rigorously.');

    // Must stay in lockstep with the recorded run's pipeline — the tape's
    // request fingerprints ARE the assertion that it does.
    const pipeline = Pipeline(
      name: 'sdd_prompt_calibration',
      result: Binding('review'),
      roles: [architect, lead, reviewer],
      mounts: [StorageMount(mountPrefix: '/workspace')],
      children: [
        Specify(
          goal: 'Add a --version flag to a small command-line tool: it '
              'prints the tool version and exits 0. Keep the spec under 300 '
              'words.',
          agent: architect,
        ),
        Plan(agent: lead),
        Review(agent: reviewer),
      ],
    );

    final program = const BasicWorkflowCompiler().compile(pipeline);

    // Robust to both invocation cwds (package dir and workspace root).
    final fixture = [
      'test/fixtures/sdd_fidelity.replay.json',
      'packages/host/vaster_playground/test/fixtures/sdd_fidelity.replay.json',
    ].map(File.new).firstWhere((f) => f.existsSync());
    final envelope =
        jsonDecode(fixture.readAsStringSync()) as Map<String, dynamic>;
    final replayModel = ReplayVasterModel(
        tape: ModelTape.fromJson(
            Map<String, dynamic>.from(envelope['modelTape'] as Map)));

    final vm = await VasterVMEngine.bootstrap(
        config: VMConfig(defaultModel: replayModel));
    final budget = ExecutionBudget.unlimited();
    final runtime = VasterRuntime(
      vm: vm,
      policy: ExecutionPolicy.unlimited,
      budget: budget,
      scheduler: BasicVasterScheduler(taskQueue: PriorityTaskQueue()),
    );

    final state = await runtime.executeProgram(program);

    expect(state.status, equals(RuntimeStatus.halted));

    // The program's declared result carries the recorded review.
    expect(program.resultBinding, equals('review'));
    final review = '${state.registers['review']}';
    expect(review, contains('APPROVE'));

    // Usage accounting replays the recorded fidelity numbers exactly.
    expect(budget.consumedTokens, equals(450302),
        reason: 'total tokens drifted from the recorded run');
    expect(budget.consumedCost, closeTo(0.825917, 1e-6),
        reason: 'wire-reported cost drifted from the recorded run');
  });
}
