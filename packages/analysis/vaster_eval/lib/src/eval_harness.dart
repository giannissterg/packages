import 'package:vaster_budget/vaster_budget.dart';
import 'package:vaster_instruction/vaster_instruction.dart';
import 'package:vaster_policy/vaster_policy.dart';
import 'package:vaster_runtime/vaster_runtime.dart';
import 'package:vaster_scheduler/vaster_scheduler.dart';
import 'package:vaster_vm_api/vaster_vm_api.dart';

import 'eval_report.dart';
import 'scorer.dart';

/// One thing to evaluate: a program under a label, on a VM the variant knows
/// how to build.
///
/// The harness never constructs engines itself — each variant owns a
/// [vmFactory] (Rule 5: the caller decides backend, tools, and config), so
/// the same harness compares fake vs claude vs replay-tape variants without
/// the eval package depending on any engine or backend.
final class EvalVariant {
  final String label;
  final VasterProgram program;
  final Future<VasterVirtualMachine> Function() vmFactory;

  /// Tears a VM down after a trial (engines expose shutdown at host level,
  /// not on the interface — the factory's owner knows how).
  final Future<void> Function(VasterVirtualMachine vm) dispose;

  const EvalVariant({
    required this.label,
    required this.program,
    required this.vmFactory,
    required this.dispose,
  });
}

/// Runs N trials per variant, scores each, and aggregates real metered
/// numbers into an [EvalReport].
///
/// Every trial is hermetic: a fresh VM and a fresh runtime, so trials can
/// never contaminate each other through sessions, context, or VFS state.
final class EvalHarness {
  final Scorer scorer;
  final int trialsPerVariant;
  final ExecutionPolicy policy;

  const EvalHarness({
    required this.scorer,
    this.trialsPerVariant = 3,
    this.policy = ExecutionPolicy.unlimited,
  });

  Future<EvalReport> run(List<EvalVariant> variants) async {
    final reports = <VariantReport>[];
    for (final variant in variants) {
      final trials = <TrialResult>[];
      for (var trial = 0; trial < trialsPerVariant; trial++) {
        trials.add(await _runTrial(variant, trial));
      }
      reports.add(VariantReport(variant: variant.label, trials: trials));
    }
    return EvalReport(variants: reports);
  }

  Future<TrialResult> _runTrial(EvalVariant variant, int trial) async {
    final vm = await variant.vmFactory();
    final budget = ExecutionBudget.unlimited();
    final runtime = VasterRuntime(
      vm: vm,
      policy: policy,
      budget: budget,
      scheduler: BasicVasterScheduler(taskQueue: PriorityTaskQueue()),
    );

    final clock = Stopwatch()..start();
    final state = await runtime.executeProgram(variant.program);
    clock.stop();

    final resultRegister = variant.program.resultBinding;
    final resultValue =
        resultRegister == null ? null : state.registers[resultRegister];
    final run = TrialRun(
        program: variant.program, state: state, resultValue: resultValue);

    final result = TrialResult(
      trial: trial,
      status: state.status,
      score: scorer.score(run),
      resultValue: resultValue,
      consumedTokens: budget.consumedTokens,
      consumedCostUsd: budget.consumedCost,
      wallClock: clock.elapsed,
      errorDetails: state.errorDetails,
    );
    await variant.dispose(vm);
    return result;
  }
}
