## Unreleased

- `ModelResponse.servedBy`: the model name that actually produced the
  response when it may differ from the model invoked (fallback chains).
  JSON key emitted only when set — tape/golden payloads stay byte-identical.
- `ResilientVasterModel` stamps `servedBy` with the serving member on every
  response, and `CancelledException` now rethrows immediately — cancellation
  is the caller's decision, never retried and never advanced past (before
  this it would retry and fall through the whole chain).

## 0.2.0

- Initial version.
