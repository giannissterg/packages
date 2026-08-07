# Changelog

## Unreleased

- `runPipeline` gains `sandboxes:` — host sandbox backends
  (`ProcessCodeSandbox`, …) for `Sandbox`/`Verify`/`Execute` subtrees;
  ISA envs bind to them by language. The umbrella barrel now exports
  the isolate and process sandbox backends.

- `runPipeline` gains `models:` — named `ModelDescriptor` → backend
  registrations, so `SelectModel` chains and descriptor-declared agents
  resolve to REAL models (previously only the default slot existed and
  every named descriptor silently fell through to it). Registered
  models ride the same recording tape as the default.

## 0.5.0

- **W0 (AST_REVIEW F0)**: `runPipeline` — the `runApp` of vaster. One
  top-level call owns the whole harness every host previously
  hand-assembled: compile, VM bootstrap, runtime composition, execution,
  optional replay-envelope recording, and teardown on every path.
  Returns a `RunReport` (state, declared result, consumed meters,
  `PipelineArtifact` list from the run's own `FileOperationEvent`
  writes, envelope path). The model choice stays explicit and required;
  HITL pauses return the paused report — parking is host policy.
