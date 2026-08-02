/// Defines how long a virtual context region persists in memory.
enum ContextLifetime {
  /// Single model request execution step only.
  ephemeral,

  /// Duration of a single step / action sub-goal.
  step,

  /// Entire duration of a model session.
  session,

  /// Static / permanent context (e.g. workspace system instructions).
  persistent,
}
