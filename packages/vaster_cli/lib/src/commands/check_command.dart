import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:vaster_check/vaster_check.dart';
import 'package:vaster_policy/vaster_policy.dart';
import 'package:vaster_pricing/vaster_pricing.dart';
import 'package:vaster_instruction/vaster_instruction.dart';

import '../vaster_command.dart';

/// `vaster check` — static verification before a single instruction runs.
///
/// Three proofs over the compiled bytecode: binding dominance (every read
/// dominated by a write on every path), a worst-case cost bound (loop trip
/// counts × prompt estimates × pricing), and policy verification (statically
/// denied resources fail NOW, interpolated ones are flagged unprovable).
class CheckCommand extends VasterCommand {
  @override
  String get name => 'check';

  @override
  String get description =>
      'Statically verifies a compiled program: binding dominance, worst-case '
      'cost bound, and policy proofs.';

  @override
  void configureArgs(ArgParser parser) {
    parser.addOption(
      'policy',
      help: 'Policy to prove against: unlimited, read-only, or a JSON file.',
    );
    parser.addOption(
      'model',
      help: 'Model name the cost bound is rated against '
          '(omit for a tokens-only bound).',
    );
    parser.addOption(
      'max-cost',
      help: 'Fail (exit 1) when the worst-case cost exceeds this many USD.',
    );
    parser.addOption(
      'response-allowance',
      help: 'Per-call response allowance in tokens (default 1024).',
    );
    parser.addFlag('json',
        negatable: false, help: 'Emit the report as machine-readable JSON.');
  }

  @override
  Future<int> execute(CommandContext context) async {
    final out = context.stdoutSink;
    final err = context.stderrSink;
    final results = context.parsedResults;

    if (results.rest.isEmpty) {
      err.writeln('Usage: vaster check <program.vbc | program.json> '
          '[--policy read-only|unlimited|<file>] [--model <name>] '
          '[--max-cost <usd>] [--json]');
      return 1;
    }
    final file = File(results.rest.first);
    if (!file.existsSync()) {
      err.writeln('Error: file not found: ${file.path}');
      return 1;
    }

    final VasterProgram program;
    try {
      program = file.path.endsWith('.vbc')
          ? VasterProgramBinary.fromBytes(file.readAsBytesSync())
          : VasterProgram.fromJson(
              jsonDecode(file.readAsStringSync()) as Map<String, dynamic>);
    } on Object catch (e) {
      err.writeln('Error: cannot load program: $e');
      return 1;
    }

    ExecutionPolicy? policy;
    final policyArg = results['policy'] as String?;
    if (policyArg != null) {
      switch (policyArg) {
        case 'unlimited':
          policy = ExecutionPolicy.unlimited;
        case 'read-only':
          policy = ExecutionPolicy.readOnly;
        default:
          final policyFile = File(policyArg);
          if (!policyFile.existsSync()) {
            err.writeln('Error: policy file not found: $policyArg');
            return 1;
          }
          policy = ExecutionPolicy.fromJson(
              jsonDecode(policyFile.readAsStringSync())
                  as Map<String, dynamic>);
      }
    }

    final checker = ProgramChecker(
      pricingCatalog: PricingCatalog.builtin,
      policy: policy,
      modelName: results['model'] as String?,
      responseAllowanceTokens:
          int.tryParse(results['response-allowance'] as String? ?? '') ?? 1024,
    );
    final report = checker.check(program);

    if (results['json'] as bool? ?? false) {
      out.writeln(const JsonEncoder.withIndent('  ').convert(report.toJson()));
    } else {
      out.writeln('── VASTER CHECK ────────────────────────────────────────');
      out.writeln('  program : ${program.programName} '
          '(${program.instructions.length} instructions)');
      final bound = report.costBound;
      final boundLine = StringBuffer('  bound   : ≤${bound.maxModelCalls} '
          'model calls, ≤${bound.maxTokens} tokens');
      if (bound.maxCostUsd != null) {
        boundLine.write(', ≤\$${bound.maxCostUsd!.toStringAsFixed(4)}');
      }
      if (bound.unbounded) boundLine.write('  [UNBOUNDED LOOP — partial]');
      out.writeln(boundLine);
      if (policy != null) {
        final proven = report.findings.whereType<PolicyViolationProven>();
        final unprovable = report.findings.whereType<PolicyUnprovable>();
        out.writeln('  policy  : ${policy.policyId} — '
            '${proven.isEmpty ? 'no proven violations' : '${proven.length} PROVEN VIOLATION(S)'}'
            '${unprovable.isEmpty ? ', fully proven' : ', ${unprovable.length} dynamic resource(s) unprovable'}');
      }
      if (report.findings.isEmpty) {
        out.writeln('  findings: none — clean');
      } else {
        out.writeln('  findings:');
        for (final finding in report.findings) {
          out.writeln('    [${finding.severity.name}] '
              '${finding.code}: ${finding.message}');
        }
      }
    }

    final maxCost = double.tryParse(results['max-cost'] as String? ?? '');
    if (maxCost != null) {
      final bound = report.costBound;
      if (bound.unbounded) {
        err.writeln('FAIL: cost bound is unbounded (--max-cost $maxCost).');
        return 1;
      }
      if (bound.maxCostUsd != null && bound.maxCostUsd! > maxCost) {
        err.writeln('FAIL: worst-case cost '
            '\$${bound.maxCostUsd!.toStringAsFixed(4)} exceeds '
            '--max-cost $maxCost.');
        return 1;
      }
    }
    return report.hasErrors ? 1 : 0;
  }
}
