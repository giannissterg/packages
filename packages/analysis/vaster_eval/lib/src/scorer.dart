import 'package:vaster_instruction/vaster_instruction.dart';
import 'package:vaster_runtime/vaster_runtime.dart';

/// Everything a scorer may inspect about one finished trial.
final class TrialRun {
  final VasterProgram program;
  final RuntimeState state;

  /// The declared result register's value, when the program declares one and
  /// it was written.
  final Object? resultValue;

  const TrialRun({required this.program, required this.state, required this.resultValue});

  String get resultText => resultValue?.toString() ?? '';
}

/// One scorer's verdict for one trial: [value] in `[0, 1]` with an optional
/// human-readable [detail].
final class ScoreResult {
  final double value;
  final String? detail;

  const ScoreResult(this.value, {this.detail})
    : assert(value >= 0 && value <= 1, 'scores are normalized to [0, 1]');

  bool get passed => value >= 1.0;

  Map<String, dynamic> toJson() => {'value': value, if (detail != null) 'detail': detail};
}

/// A quality judgment over one trial — composable, engine-agnostic.
///
/// Scorers are pure inspections of a finished [TrialRun]; they never talk to
/// models themselves (a model-graded scorer wraps a `VasterModel` the CALLER
/// owns — Rule 5 — and is still just a Scorer from the harness's view).
abstract interface class Scorer {
  /// Stable id used in reports (e.g. `halted`, `contains:GO`).
  String get id;

  ScoreResult score(TrialRun trial);
}

/// 1.0 iff the machine halted (traps, timeouts, and pauses all fail).
final class HaltedScorer implements Scorer {
  const HaltedScorer();

  @override
  String get id => 'halted';

  @override
  ScoreResult score(TrialRun trial) => trial.state.status == RuntimeStatus.halted
      ? const ScoreResult(1)
      : ScoreResult(
          0,
          detail:
              'status ${trial.state.status.name}'
              '${trial.state.errorDetails == null ? '' : ': ${trial.state.errorDetails}'}',
        );
}

/// 1.0 iff the declared result contains [needle] (case-sensitive).
final class ContainsScorer implements Scorer {
  final String needle;

  const ContainsScorer(this.needle);

  @override
  String get id => 'contains:$needle';

  @override
  ScoreResult score(TrialRun trial) => trial.resultText.contains(needle)
      ? const ScoreResult(1)
      : ScoreResult(
          0,
          detail:
              'result did not contain "$needle" '
              '(got: "${trial.resultText.length > 80 ? '${trial.resultText.substring(0, 80)}…' : trial.resultText}")',
        );
}

/// 1.0 iff the declared result matches [pattern].
final class RegexScorer implements Scorer {
  final RegExp pattern;

  RegexScorer(String pattern) : pattern = RegExp(pattern);

  @override
  String get id => 'regex:${pattern.pattern}';

  @override
  ScoreResult score(TrialRun trial) => pattern.hasMatch(trial.resultText)
      ? const ScoreResult(1)
      : ScoreResult(0, detail: 'no match for /${pattern.pattern}/');
}

/// A caller-supplied judgment — the escape hatch for domain-specific checks
/// and model-graded scoring (close over a model you own).
final class FunctionScorer implements Scorer {
  @override
  final String id;
  final ScoreResult Function(TrialRun trial) fn;

  const FunctionScorer(this.id, this.fn);

  @override
  ScoreResult score(TrialRun trial) => fn(trial);
}

/// The mean of its children — a trial's composite quality.
final class AllOfScorer implements Scorer {
  final List<Scorer> children;

  const AllOfScorer(this.children);

  @override
  String get id => 'allOf(${children.map((s) => s.id).join(', ')})';

  @override
  ScoreResult score(TrialRun trial) {
    if (children.isEmpty) return const ScoreResult(1);
    var sum = 0.0;
    final failures = <String>[];
    for (final child in children) {
      final result = child.score(trial);
      sum += result.value;
      if (!result.passed) {
        failures.add('${child.id}: ${result.detail ?? 'failed'}');
      }
    }
    return ScoreResult(sum / children.length, detail: failures.isEmpty ? null : failures.join('; '));
  }
}
