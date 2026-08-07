## 0.5.0

- **BREAKING (B2)**: the engine's prompt verbs require an explicit
  model (no `?? config.defaultModel` fallback inside); `createAgent`
  resolves the descriptor chain, then the VM default.

- **A4**: agent chain resolution delegates to the shared
  `ModelChainResolver` — twin composer deleted.

- **A1**: the VM composes each agent's gate — program-policy binding
  plus, when the descriptor declares one, its own policy
  (`CompositeToolCallGate`). `AgentDescriptor.policy` was a dormant
  field; it is enforced now.

- **BREAKING (Rule 11 V1)**: registration/mount verbs return handles
  and displaced entities; the mount event now carries the NORMALIZED
  prefix.

- `agentToolRecorder` binding constructed at bootstrap and wired into
  the agent manager (GAP-3a).

- `createAgent` resolves a descriptor-declared model chain (GAP-3b):
  same one-attempt `ResilientVasterModel` composition as the runtime's
  active model — model-kind failures advance (publishing
  `ModelFallbackEvent`), cancellation never does, the serving member
  stamps `servedBy`. Precedence: explicit host `model:` → descriptor
  chain → VM default.
- The prompt funnel's metering honors `ModelResponse.servedBy` (REL-P3):
  when a fallback-chain member serves a call, usage is attributed (and
  priced) to that member, not the model the caller invoked.

## 0.3.0

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
