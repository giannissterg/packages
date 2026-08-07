# Changelog

## Unreleased

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
