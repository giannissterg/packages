## Unreleased

- New optional `onTurnUsage` construction hook reporting each model turn's
  usage (measured or labeled estimate) to the wiring owner.
- Task-metadata `cacheHints` are decoded into `ModelRequest.cacheHints` —
  agent prompts now carry cache breakpoints.

## 0.2.0

- Initial version.
