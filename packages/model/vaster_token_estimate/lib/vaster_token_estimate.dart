/// Heuristic token estimation — the single home for length-based token
/// counts in the Vaster ecosystem.
///
/// Concept unawareness: estimation must NOT know about quotas, budgets,
/// costs, sessions, or opcode execution. It maps text to approximate token
/// counts, nothing else.
library;

export 'src/token_estimate.dart';
