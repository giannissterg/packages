## Unreleased

- **W2 (AST_REVIEW F2)**: whole-subtree role collection. Every
  `AgentRole` the tree names through an `agent:` slot provisions
  automatically at the slot `Pipeline` reserves — `roles:` is only
  needed for `agentId:` string references. One id, one definition: a
  second, different definition under the same roleId is a compile error
  (`conflicting_agent_role`). Pipelines that declare their roles compile
  to byte-identical programs.

- **BREAKING (Rule 11 V5)**: the IR builder hands back stream handles —
  `emit`/`jump`/`jumpIf`/`call`/`pushErrorHandler`/`decide` return the
  emitted item's IR index, `bind` echoes the label it bound (the
  allocate-bind-capture idiom: `final head = ir.bind(ir.newLabel(...))`),
  `_lowerNode`/`_lowerNodes` return the emitted `[start, end)` range —
  the substrate for source maps and per-subtree assertions. Analyzer
  check helpers return the diagnostics they add (null/empty when clean).

- Agent provisioning threads `AgentRole.model`/`modelFallbacks` into the
  emitted `AgentDescriptor` (GAP-3b); `CapabilityAudit` lists agent
  chains (`agent <id>: a → b`) and counts their members as selectable
  models.
- `SelectModelHeader` lowering carries the fallback chain into
  `SelectModelOp` (REL-P3), and `CapabilityAudit` lists declared chains:
  every member joins `models`, and `modelChains` renders each chain in
  declaration order (`primary → fb1 → fb2`).

## 0.2.0

- Initial version.
