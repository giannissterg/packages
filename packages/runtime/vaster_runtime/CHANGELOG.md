## Unreleased

- **A2**: the engine's program-registered `write_file`/`read_file`
  tools delegate to the ONE `VfsSyscalls` implementation — the third
  hand-rolled copy (drifted output shape, bypassed shared path) is gone;
  a test locks the canonical `{'status':'ok','path':…}` shape.
- **A4**: the active-model chain composes via the shared
  `ModelChainResolver` (vm_api) — the 22-line twin is gone.

- **A1 (security)**: the ISA tool loop and the agent tool loop are now
  the SAME pipeline (`ToolTurnRunner`). `PolicyGuard` implements
  `ToolCallGate` and the runtime binds it into the VM's agent gate — so
  agent-internal tool calls answer to the program's execution policy,
  which they previously did NOT. `ToolCallReplayedEvent` has one owner
  (the recorder); the orchestrator's duplicate publish is gone. The
  orchestrator takes a `ToolEffectRecorder` (shared with agents) instead
  of the ledger directly. `PolicyGuard.check` echoes its resource
  (Rule 11).

- Rule 11 V8: `EffectLedger` scope ops return depths (push/pop/unwind)
  and reset counts (markRetry, clear); `CallStack.push` returns the new
  depth.

- Rule 11 V3: `CacheHintTracker.onRegionPinned` returns the hint now
  tracked (null when the region has no live descriptor), `removeHint`
  the hint it removed, `clear` how many it dropped.

- Rule 11 V1 consumer: `AddContextOp` uses the displaced-region handle
  to drop the stale cache hint when a PINNED region is replaced by
  unpinned content (latent stale-fingerprint hole).

- `LedgerToolEffectRecorder` (GAP-3a): the runtime binds its effect
  ledger into the VM's agent-loop recorder binding, so agent-internal
  tool calls share the machine's dedup memory — scoped per dispatch
  (the GAP-2 claim's `slotId` rides task metadata as the agent's
  `EffectRegion`), reset by `MarkEffectRetryOp`, checkpoint-safe. VFS
  syscalls claim inert (transactions own them); every replay publishes
  `ToolCallReplayedEvent`. `EffectLedger.commit` echoes its result and
  `EffectClaim.slotId` names the claimed slot (Rule 11).

- **Agent dispatches join the effect ledger (GAP-2).** Inside an effect
  scope, `DispatchAgentTaskOp` and each entry of
  `DispatchParallelTasksOp` claim occurrence slots; a retried attempt
  replays recorded successful `AgentOutput`s instead of re-running the
  tasks — completed work is never re-run and never re-charged (typed
  `AgentTaskReplayedEvent` per replay). A retried parallel batch replays
  its successes and re-dispatches only the failures. New
  `EffectLedger.claim`/`commit` primitives (batch consumers claim in
  declaration order before fanning out); `executeOrReplay` is sugar over
  them.
- Unpaired `CommitOp`/`RollbackOp` (no open transaction) publish a
  `transaction_unpaired` warning (GAP-1, Rule 2) — an empty-stack commit
  means rollback protection was lost somewhere, and that must be visible.
- **Idempotency at the effect boundary (REL-P4).** The `EffectLedger`
  (componentized machine state, checkpoint-safe) records non-VFS tool
  results inside an effect scope; a retry attempt REPLAYS a recorded
  result instead of re-executing the side effect, publishing a typed
  `ToolCallReplayedEvent`. Replays don't count against the tool-call
  quota. VFS syscalls bypass the ledger — the transaction machinery owns
  compensable effects.
- **Error unwinding is real.** A caught failure now unwinds what the
  failed region abandoned before control transfers: open VFS transactions
  above the handler's mark roll back (making `Transaction`'s documented
  rollback-on-failure actually happen — previously a caught failure
  leaked the partial writes), and effect scopes above it close.
  `ErrorHandlerFrame` records both depths at push (additive JSON).
- **BREAKING**: collaborators hold VM facets, not the VM (ISP) —
  `DecisionArbiter(funnel:, meter:, defaultModel:)` takes the
  `PromptFunnel`; `ToolCallOrchestrator(host:, …, defaultModel:)` takes the
  `ToolLoopHost`. The runtime engine remains the only component programming
  against the master `VasterVirtualMachine` interface.
- **BREAKING**: `DecisionArbiter.decide` returns a sealed `DecisionOutcome`
  (`DecisionChosen` / `DecisionUnresolved`) instead of a
  `({String? label, String? rationale})` record whose null label secretly
  meant "use the default". The unresolved variant carries the model's raw
  answer, so the no-default trap now says WHAT the model said.
- `HitlController` owns its event bus at construction (Rule 5) —
  `pause(request:, currentPc:)` no longer takes a per-invocation bus.
- Model fallback chains are runtime-enforced (REL-P3): `SelectModelOp`
  fallbacks land in `MachineContext.activeModelFallbacks` (componentized
  state — checkpoint/resume covered by the gauntlet), and the active model
  resolves as a `ResilientVasterModel` composition with a one-attempt
  policy: each member tried once, model-kind failures advance, cancellation
  and policy violations never do. Every advance publishes a typed
  `ModelFallbackEvent`; metering attributes each call to the response's
  `servedBy` stamp — a fallback-served call is priced at the fallback's
  rate, not the chain head's.

## 0.4.0

- Sealed `MachinePhase` (`PhaseIdle/Running/Halted/PausedForHuman/Trapped/
  TimedOut`) replaces the status-enum + error-string + separate-getter
  scatter internally — a pause carries its request, a trap carries its
  report. Exposed as `VasterRuntime.phase`; `RuntimeState.status`/
  `errorDetails` remain as projections (`asStatus`/`errorDetails`).

- **BREAKING**: machine state is componentized. `MachineContext` (session /
  model descriptor / toolset / error handlers) joins RegisterFile, CallStack,
  HitlController, and a QuotaStateAdapter as `MachineStateComponent`s;
  `captureSnapshot`/`restoreSnapshot` fold over the single `_stateComponents`
  registration; `restoreAndResume(MachineSnapshot, program, {humanResponse})`
  replaces the eight-parameter surface. The live model is derived from its
  descriptor on use.

## 0.4.0

- Checkpoint surface: `activeSessionId` / `activeModelDescriptor` /
  `programToolSet` / `errorHandlersSnapshot` getters, `restoreQuota`, and
  `restoreAndResume` accepts the machine-internal state (session, model,
  toolset, error handlers) plus rebuilds cache hints from restored pinned
  regions. Fixes resumed prompts running sessionless.

## 0.3.0

- `RegisterFile.jsonExtract` returns a sealed `ExtractOutcome`
  (`ExtractOk` / `ExtractSourceMissing` / `ExtractParseFailure` /
  `ExtractKeyMissing` with available keys) instead of silently no-oping;
  the engine publishes typed `RuntimeWarningEvent`s (`extract_source_missing`,
  `extract_parse_error`, `extract_key_missing`) while keeping the tolerant
  no-trap semantics.

- **BREAKING**: `VasterRuntime` builds its full collaborator graph eagerly in
  a factory constructor (no `late final` lazy initialization); metering routes
  through one `ModelCallMeter` (host budget + program quota) instead of six
  hand-rolled charge sites.
- **BREAKING**: depends on `vaster_vm_api` instead of `vaster_vm` — the
  runtime ⇄ vm cycle is gone; all previously barrel-hidden dependencies are
  declared explicitly.
- **BREAKING**: `ExecutionTracer` moved to `package:vaster_dis/tracer.dart`.
- `DispatchParallelTasksOp` works against any `AgentManager` (interface
  method, no more downcast + silent skip) and gives each parallel dispatch a
  unique `parallel_<pc>_<i>` taskId.
- Cache hints forwarded to dispatched agents are now applied (previously
  packed into task metadata and dropped).

## 0.2.0

- Initial version.
