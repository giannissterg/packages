import 'check_finding.dart';
import 'cost_bound.dart';

/// Everything `vaster check` proves (or refuses to prove) about a program.
final class CheckReport {
  final List<CheckFinding> findings;
  final CostBound costBound;

  const CheckReport({required this.findings, required this.costBound});

  bool get hasErrors =>
      findings.any((f) => f.severity == CheckSeverity.error);

  Iterable<CheckFinding> bySeverity(CheckSeverity severity) =>
      findings.where((f) => f.severity == severity);

  Map<String, dynamic> toJson() => {
        'findings': [for (final f in findings) f.toJson()],
        'costBound': costBound.toJson(),
      };
}
