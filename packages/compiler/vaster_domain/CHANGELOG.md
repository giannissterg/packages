# Changelog

## Unreleased

- **W1 (AST_REVIEW F3)**: `AgentRole.name`/`title` are optional —
  `name` defaults to `roleId`, `title` to `name`. A persona is an id
  plus an instruction; display names are opt-in. Serialized shape
  unchanged.

- **W1 (AST_REVIEW F6)**: `StorageMount.disk('/prefix', hostPath)` and
  `StorageMount.memory('/prefix')` factory constructors.

- `AgentRole.model` + `modelFallbacks` (GAP-3b): agent model chains are
  declarable in the workflow language; the compiler threads them into
  the emitted `AgentDescriptor`.

## 0.2.0

- Breaking: `ParallelTaskEntry(agentId:, prompt:)` (was
  `agentRoleId`/`promptText`); its `output` is now honored by the compiler.
- Removed the unused `TaskDefinition`.
- `human_interaction.dart` moved to `vaster_instruction` (ISA payload).

## 0.0.1

- Initial version.
