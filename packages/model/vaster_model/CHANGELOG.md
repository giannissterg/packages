## Unreleased

- **Bring-your-own-model is the first-class integration.**
  `VasterModel.fromHandler` wraps the caller's OWN model invocation —
  any SDK, proxy, or local server — as a full `VasterModel`: the handler
  sees the complete request (messages, system instruction, tools,
  `responseSchema`, `cancelToken`) and owns the response, including real
  usage when it has it. `VasterModel.fromTextHandler` is the simple
  tier: same request in, plain text out, default usage — the machine's
  metering estimates and charges it. Streaming defaults to the
  one-terminal-chunk synthesis of non-streaming backends
  (`onGenerateStream` overrides). Exceptions propagate untouched, so
  `ResilientVasterModel`, `RecordingVasterModel`, and cancellation
  compose exactly as for shipped backends. Zero new dependencies.

## 0.5.0

- **D**: `CancellationToken`/`CancelledException` moved to the new
  `vaster_cancellation` leaf package and are re-exported here —
  non-breaking for consumers of this package; packages that only need
  cancellation (the sandboxes) now depend on the leaf directly.

- **A4**: `ModelRetryEvent.modelIndex` — the failed member's chain
  index (0 = primary). Exact where a name lookup is not: a chain may
  contain the same model name twice, and hop reporting now survives it.

- Rule 11 V6: `CancellationToken.cancel` returns whether THIS call
  performed the transition — the first cause wins, repeats are
  observable no-ops.

- `ModelResponse.servedBy`: the model name that actually produced the
  response when it may differ from the model invoked (fallback chains).
  JSON key emitted only when set — tape/golden payloads stay byte-identical.
- `ResilientVasterModel` stamps `servedBy` with the serving member on every
  response, and `CancelledException` now rethrows immediately — cancellation
  is the caller's decision, never retried and never advanced past (before
  this it would retry and fall through the whole chain).

## 0.2.0

- Initial version.
