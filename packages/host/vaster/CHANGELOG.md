# Changelog

## 0.5.0

- **W0 (AST_REVIEW F0)**: `runPipeline` — the `runApp` of vaster. One
  top-level call owns the whole harness every host previously
  hand-assembled: compile, VM bootstrap, runtime composition, execution,
  optional replay-envelope recording, and teardown on every path.
  Returns a `RunReport` (state, declared result, consumed meters,
  `PipelineArtifact` list from the run's own `FileOperationEvent`
  writes, envelope path). The model choice stays explicit and required;
  HITL pauses return the paused report — parking is host policy.
