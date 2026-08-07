import 'dart:io';

import 'package:vaster_benchmarks/vaster_benchmarks.dart';
import 'package:vaster_vm/vaster_vm.dart';

/// Exports the live-runnable benchmarks as compiled `.vbc` artifacts for
/// the live-run protocol (`docs/RELIABILITY.md`):
///
///     dart run vaster_benchmarks:export
///     vaster eval artifacts/benchmarks/sdd_multi_agent.vbc \
///         --backend claude-cli -n 3 --contains APPROVE
///
/// Fault-injection benchmarks are CI-only (their failure shapes need
/// injected models a live backend cannot produce on demand) and are
/// skipped here with a note.
void main() {
  final outDir =
      Directory('../../../artifacts/benchmarks').existsSync() || Directory('../../../artifacts').existsSync()
      ? Directory('../../../artifacts/benchmarks')
      : Directory('artifacts/benchmarks');
  outDir.createSync(recursive: true);

  for (final benchmark in ReliabilityBenchmarks.builtin.all) {
    if (!benchmark.liveRunnable) {
      stdout.writeln('skip ${benchmark.id}  (fault-injection, CI-only)');
      continue;
    }
    final file = File('${outDir.path}/${benchmark.id}.vbc');
    file.writeAsBytesSync(benchmark.program().toBytes());
    stdout.writeln('wrote ${file.path}');
  }
  stdout.writeln('\nRun the live protocol per docs/RELIABILITY.md, e.g.:');
  stdout.writeln('  vaster eval <artifact>.vbc --backend claude-cli -n 3');
}
