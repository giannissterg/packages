## Unreleased

- **BREAKING (Rule 11 V6)**: `pauseAgent`/`resumeAgent` return the
  sealed `AgentLifecycle` the agent is now in — the transition is data.

- `toolEffectRecorder` construction collaborator (GAP-3a, canonical
  no-op default) wired into every agent this manager creates.

## 0.3.0

- **Actor semantics**: tasks for the same agent are serialized FIFO through
  a per-agent `AgentMailbox` (one session, one transcript, one task at a
  time); tasks for different agents still run concurrently. `pauseAgent`
  gates both acceptance and dequeue, and a mid-run pause is no longer
  overwritten back to idle when the task completes.
- Internal restructure by composition: one `_AgentEntry` per agent (agent +
  sealed lifecycle + tree links + mailbox) replaces four parallel maps;
  `unregisterAgent` no longer leaks a terminated state entry forever. New
  `lifecycleOf(agentId)` exposes the full sealed lifecycle.

- New optional `onTurnUsage` listener wired into every created agent; when
  installed, its owner emits per-turn usage events and the manager's
  task-level `ModelUsageEvent` rollup is suppressed (no double counting).
- Agent session ids come from `AgentDescriptor.sessionIdFor`.

## 0.2.0

- Initial version.
