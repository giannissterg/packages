/// Priority levels assigned to virtual context regions.
/// Higher priority regions are preserved longer during context budget eviction.
enum ContextPriority {
  /// Ephemeral context (scraps, scratch outputs, transient observations).
  ephemeral,

  /// Low priority context (old step logs, background info).
  low,

  /// Medium priority context (recent history, secondary files).
  medium,

  /// High priority context (core active files, active task instructions).
  high,

  /// Critical context (system prompt, mandatory tools, explicit user prompt). Never evicted.
  critical;

  /// Parses a name, defaulting to [medium] for unknown values.
  static ContextPriority parse(String? value) =>
      ContextPriority.values.firstWhere((p) => p.name == value, orElse: () => ContextPriority.medium);
}
