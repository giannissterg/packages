## Unreleased

- **BREAKING**: `submitProgram` requires `policy` and `budget`
  (`customBudget` renamed) — no silent unlimited-policy fallback.
- The engine meters every model call it owns through a public
  `ModelCallMeter` (`meter`): prompt funnel, per-turn agent usage
  (`agent_turn` events with cost), and context compression
  (`context_compression` events) — the latter two were previously off-books.
- `VasterVirtualMachine.defaultRootAgentId` documents the `runAgentTask`
  fallback agent; VFS syscall tools delegate to the shared `VfsSyscalls`.

## 0.2.0

- Initial version.
