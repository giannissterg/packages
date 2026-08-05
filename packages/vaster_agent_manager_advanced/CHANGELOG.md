## Unreleased

- New optional `onTurnUsage` listener wired into every created agent; when
  installed, its owner emits per-turn usage events and the manager's
  task-level `ModelUsageEvent` rollup is suppressed (no double counting).
- Agent session ids come from `AgentDescriptor.sessionIdFor`.

## 0.2.0

- Initial version.
