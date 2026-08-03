/// The strongest transformation a context region may undergo under budget
/// pressure. Levels are ordered: `summarize` permits everything `truncate`
/// does; `none` forbids any alteration.
enum ContextCompressibility {
  /// The region must never be altered (default — safe).
  none,

  /// Deterministic truncation is allowed (dropping messages, no model calls).
  truncate,

  /// Model-backed summarization is preferred; truncation is a legal fallback.
  summarize;

  /// Parses a name, defaulting to [none] for unknown values.
  static ContextCompressibility parse(String? value) =>
      ContextCompressibility.values.firstWhere(
        (c) => c.name == value,
        orElse: () => ContextCompressibility.none,
      );
}
