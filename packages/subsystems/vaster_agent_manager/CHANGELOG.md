## Unreleased

- **BREAKING (Rule 11 V1)**: `registerAgent` returns the same-id agent
  it displaced.

## 0.3.0

- New sealed `AgentLifecycle` (`AgentIdle` / `AgentRunning` with active
  taskId + queue depth / `AgentPaused` / `AgentTerminated`) with an
  `asState` projection onto the legacy `AgentState` enum.

- **BREAKING**: `createAgent` requires `contextManager` and `toolManager`
  (Rule 5 — ownership is stated, never defaulted silently).
- **BREAKING**: `dispatchParallelTasks` is part of the `AgentManager`
  interface.

## 0.2.0

- Initial version.
