import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:vaster_eval/vaster_eval.dart';
import 'package:vaster_vm/vaster_vm.dart';

import '../vaster_command.dart';
import 'backend_resolver.dart';

/// `vaster eval` — does the pipeline WORK, how often, and at what cost?
///
/// Runs a compiled program N times on the chosen backend, scores every trial
/// (halted + optional content assertions on the declared result), and
/// reports success rate with real metered tokens/cost per trial.
class EvalCommand extends VasterCommand {
  @override
  String get name => 'eval';

  @override
  String get description => 'Runs a compiled program N times and reports success rate, score, and '
      'real metered cost per trial.';

  @override
  ArgParser configureArgs(ArgParser parser) {
    parser.addOption('trials', abbr: 'n', help: 'Trials to run (default 3).');
    parser.addOption(
      'backend',
      help: 'Model backend '
          '(fake|claude-api|claude-cli|gemini|gemini-cli|rpc).',
    );
    parser.addOption('model', help: 'Backend-specific model name.');
    parser.addMultiOption('contains',
        help: 'Pass only when the declared result contains this text '
            '(repeatable — all must hold).');
    parser.addOption('regex', help: 'Pass only when the declared result matches this pattern.');
    parser.addFlag('json', negatable: false, help: 'Emit the report as machine-readable JSON.');
    return parser;
  }

  @override
  Future<int> execute(CommandContext context) async {
    final out = context.stdoutSink;
    final err = context.stderrSink;
    final results = context.parsedResults;

    if (results.rest.isEmpty) {
      err.writeln('Usage: vaster eval <program.vbc | program.json> '
          '[--trials N] [--backend fake|...] [--contains <text>]... '
          '[--regex <pattern>] [--json]');
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
          : VasterProgram.fromJson(jsonDecode(file.readAsStringSync()) as Map<String, dynamic>);
    } on Object catch (e) {
      err.writeln('Error: cannot load program: $e');
      return 1;
    }

    final scorer = AllOfScorer([
      const HaltedScorer(),
      for (final needle in results['contains'] as List<String>) ContainsScorer(needle),
      if (results['regex'] != null) RegexScorer(results['regex'] as String),
    ]);

    final backend = results['backend'] as String? ?? 'fake';
    final harness = EvalHarness(
      scorer: scorer,
      trialsPerVariant: int.tryParse(results['trials'] as String? ?? '') ?? 3,
    );
    final report = await harness.run([
      EvalVariant(
        label: backend,
        program: program,
        vmFactory: () async => VasterVMEngine.bootstrap(
          config: VMConfig(
            defaultModel: (await resolveBackendModel(results: results, context: context, err: err)).model,
          ),
        ),
        dispose: (vm) => (vm as VasterVMEngine).shutdown(),
      ),
    ]);

    if (results['json'] as bool? ?? false) {
      out.writeln(const JsonEncoder.withIndent('  ').convert(report.toJson()));
    } else {
      final v = report.variants.single;
      out.writeln('── VASTER EVAL ─────────────────────────────────────────');
      out.writeln('  program : ${program.programName}');
      out.writeln('  variant : ${v.variant}  (scorer: ${scorer.id})');
      out.writeln('  trials  : ${v.trialCount}');
      out.writeln('  success : ${v.passed}/${v.trialCount} '
          '(${(v.successRate * 100).toStringAsFixed(0)}%)  '
          'mean score ${v.meanScore.toStringAsFixed(2)}');
      out.writeln('  spend   : ${v.totalTokens} tokens'
          '${v.totalCostUsd > 0 ? ' / \$${v.totalCostUsd.toStringAsFixed(6)}' : ''}'
          '  mean ${v.meanWallClock.inMilliseconds}ms/trial');
      for (final t in v.trials) {
        final mark = t.score.passed ? 'PASS' : 'fail';
        out.writeln('    #${t.trial} $mark  ${t.status.name}  '
            '${t.consumedTokens}tok'
            '${t.score.detail == null ? '' : '  — ${t.score.detail}'}');
      }
    }

    return report.variants.single.successRate == 1.0 ? 0 : 1;
  }
}
