/// The tracker's consumed meters at a moment — a Snapshot, not a Report
/// (it echoes state, it does not summarize work). Named per Rule 11:
/// this shape crossed the public boundary as an anonymous record.
final class ConsumptionSnapshot {
  final int tokens;
  final double cost;
  final int toolCalls;

  const ConsumptionSnapshot({required this.tokens, required this.cost, required this.toolCalls});

  static const zero = ConsumptionSnapshot(tokens: 0, cost: 0, toolCalls: 0);

  @override
  String toString() => 'ConsumptionSnapshot($tokens tok, \$$cost, $toolCalls tool call(s))';
}
