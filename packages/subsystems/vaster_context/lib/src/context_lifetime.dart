/// Defines how long a virtual context region persists in memory.
enum ContextLifetime {
  /// Single model request execution step only.
  ephemeral,

  /// Duration of a single step / action sub-goal.
  step,

  /// Entire duration of a model session.
  session,

  /// Static / permanent context (e.g. workspace system instructions).
  persistent;

  /// Parses a name, defaulting to [session] for unknown values.
  static ContextLifetime parse(String? value) => ContextLifetime.values
      .firstWhere((l) => l.name == value, orElse: () => ContextLifetime.session);
}
