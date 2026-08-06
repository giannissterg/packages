import 'package:test/test.dart';
import 'package:vaster_benchmarks/vaster_benchmarks.dart';
import 'package:vaster_eval/vaster_eval.dart';

/// THE gate-4 CI run: every reliability benchmark executes at zero token
/// cost — recorded tapes for real-backend fidelity, deterministic fault
/// injection for the semantics no live backend produces on demand — and
/// every one must pass every trial. The printed table is the source of
/// the numbers `docs/RELIABILITY.md` publishes.
void main() {
  test('the reliability benchmark set passes end to end', () async {
    final rows =
        <({ReliabilityBenchmark benchmark, VariantReport report})>[];

    for (final benchmark in ReliabilityBenchmarks.builtin.all) {
      final harness = EvalHarness(
        scorer: benchmark.scorer,
        trialsPerVariant: benchmark.ciTrials,
      );
      final report = await harness.run([benchmark.ciVariant()]);
      final variant = report.variants.single;
      rows.add((benchmark: benchmark, report: variant));

      expect(variant.successRate, 1.0,
          reason: '${benchmark.id}: '
              '${variant.trials.map((t) => t.score.detail).join('; ')}');

      // Tape benchmarks are fidelity locks: the replayed totals must equal
      // the recorded real run's, token for token, cent for cent.
      if (benchmark.expectedTokens != null) {
        expect(variant.totalTokens, benchmark.expectedTokens,
            reason: '${benchmark.id}: total tokens drifted from the '
                'recorded run');
      }
      if (benchmark.expectedCostUsd != null) {
        expect(variant.totalCostUsd,
            closeTo(benchmark.expectedCostUsd!, 1e-6),
            reason:
                '${benchmark.id}: cost drifted from the recorded run');
      }
    }

    // The published table, visible in every CI log.
    // ignore: avoid_print
    print(renderBenchmarkTable(rows));
  }, timeout: const Timeout(Duration(minutes: 5)));
}
