## Unreleased (machine-state era)

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

## Unreleased

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
