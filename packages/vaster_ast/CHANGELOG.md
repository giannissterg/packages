# Changelog

## 0.2.0

- **Breaking — declarative-only default import**: imperative primitives
  live in `package:vaster_ast/primitives.dart`; compiler lowering targets in
  `package:vaster_ast/lowering.dart`. The main import is the declarative
  tier only.
- **Breaking — scope providers take `child:`**: `ToolSet`, `Mount`,
  `Sandbox`, `SelectModel`, `BudgetScope`, `Inputs` (matching
  `Agent`/`Knowledge`/`ContextBudget`); wrap former sibling lists in
  `Sequence`. Omitting `child` provisions/declares without scoping.

Breaking DX overhaul — see the root CHANGELOG for the full narrative.

- Vocabulary unified (`prompt`, `condition`, `counter`, `error`, `output`,
  `from`); `Agent(child:)` single-subtree provider; `Pipeline(name:)` with
  real provisioning of declared roles/mounts/tools/model.
- New: `output:` bindings + `${...}` interpolation, `Inputs`, `Extract`,
  `Sequence`, `Decide`/`DecideLoop`, `Knowledge`, `ContextBudget`, the
  coordination library (`AgentTeam`, `FanOut`, `RefineLoop`, `Router`,
  `Resilient`, `Produce`), and the SDD kit (`Clarify`, `Specify`, `Plan`,
  `Review`, `Implement`, `Verify`).
- Removed: `PinContext`, `UnpinContext`, `ContextPolicy`, the
  `ProviderNode` typedef, and Flutter demo components (moved to
  `vaster_playground`).
- Design rules documented in-source: nest vs sequence, and the base-node
  admission test (sugar lowering targets only).

## 0.0.1

- Initial version.
