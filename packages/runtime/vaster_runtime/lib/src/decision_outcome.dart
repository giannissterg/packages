/// How a [DecideOp] arbitration ended — **sealed, carrying its data**
/// (rules.md Rule 2), replacing the `({String? label, String? rationale})`
/// record whose null label secretly meant "fall back to the default".
///
/// The engine consumes this exhaustively: a chosen label routes; an
/// unresolved answer routes to the op's `defaultLabel` — and when no valid
/// default exists, the trap can finally say WHAT the model answered,
/// because the unresolved variant carries it.
sealed class DecisionOutcome {
  /// The model's stated reasoning, when it provided one.
  final String? rationale;

  const DecisionOutcome({this.rationale});
}

/// The model's answer resolved to one of the offered branch labels.
final class DecisionChosen extends DecisionOutcome {
  final String label;

  const DecisionChosen({required this.label, super.rationale});
}

/// The model's answer matched no offered label. [rawAnswer] is the text it
/// actually produced — observable data for the default-branch event or the
/// no-default trap, never silently discarded.
final class DecisionUnresolved extends DecisionOutcome {
  final String rawAnswer;

  const DecisionUnresolved({required this.rawAnswer, super.rationale});
}
