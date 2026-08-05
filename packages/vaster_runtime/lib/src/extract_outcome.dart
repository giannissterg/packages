/// What happened when a `JsonExtractOp` ran — modeled as data, not silence.
///
/// Extraction stays *tolerant* (a miss never traps the machine: model output
/// is untrusted and a missing field is normal weather), but tolerance without
/// observability made failures vanish — the target register stayed unset and
/// the first symptom was an `unresolved_interpolation` warning far
/// downstream. The sealed hierarchy forces the engine's switch to handle
/// every failure shape explicitly, and each shape carries exactly the data
/// its diagnostic needs.
sealed class ExtractOutcome {
  const ExtractOutcome();
}

/// The key was found; [value] was written to the target register.
final class ExtractOk extends ExtractOutcome {
  final Object? value;

  const ExtractOk(this.value);
}

/// The source register itself is unset — nothing to extract from.
final class ExtractSourceMissing extends ExtractOutcome {
  final String sourceVar;

  const ExtractSourceMissing({required this.sourceVar});
}

/// The source register's value could not be parsed as a JSON object.
final class ExtractParseFailure extends ExtractOutcome {
  final String sourceVar;

  /// Parser detail (never model content — previews could leak prompt data
  /// into logs).
  final String detail;

  const ExtractParseFailure({required this.sourceVar, required this.detail});
}

/// The JSON parsed, but the requested key is not in the object.
final class ExtractKeyMissing extends ExtractOutcome {
  final String sourceVar;
  final String jsonKey;

  /// The keys that WERE present — the diagnostic that turns "extraction
  /// silently failed" into "you asked for `verdict` but the model returned
  /// `Verdict`".
  final List<String> availableKeys;

  const ExtractKeyMissing({
    required this.sourceVar,
    required this.jsonKey,
    required this.availableKeys,
  });
}
