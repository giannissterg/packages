import 'package:test/test.dart';
import 'package:vaster_check/vaster_check.dart';
import 'package:vaster_compiler/vaster_compiler.dart';
import 'package:vaster_vm/vaster_vm.dart';

import 'harness/war_room_harness.dart';

/// The static verifier against REAL compiler output: every loop the compiler
/// emits carries a recognizable bound, and the richest pipeline we have
/// checks clean.
void main() {
  const compiler = BasicWorkflowCompiler();

  test('the compiled war room has a finite cost bound and no errors', () {
    final program = compiler.compile(warRoom());
    final report = ProgramChecker(
      pricingCatalog: PricingCatalog.builtin,
      modelName: 'claude-sonnet-5',
    ).check(program);

    expect(report.costBound.unbounded, isFalse,
        reason: 'every compiler-emitted loop must carry its maxIterations '
            'guard in recognizable form; unbounded findings: '
            '${report.findings.whereType<UnboundedLoop>().map((f) => f.message)}');
    expect(report.costBound.maxModelCalls, greaterThan(0));
    expect(report.costBound.maxCostUsd, isNotNull);
    expect(report.hasErrors, isFalse,
        reason: 'errors: ${report.bySeverity(CheckSeverity.error).map((f) => f.message)}');
  });
}
