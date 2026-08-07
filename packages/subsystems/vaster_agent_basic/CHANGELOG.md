## 0.5.0

- **A1**: the tool loop runs through the shared `ToolTurnRunner` with a
  `ToolCallGate` collaborator; `PolicyViolationException` rethrows past
  the task-outcome catch-all (a security trap is never a task outcome).
  Subagents inherit gate and recorder.

- Tool calls execute through a `ToolEffectRecorder` (GAP-3a): inside a
  dispatch's effect region, a re-dispatched task replays recorded tool
  results instead of re-executing side effects; only really-executed
  calls count against the tool-call quota. Subagents inherit the
  recorder.

- Per-turn usage attribution honors `ModelResponse.servedBy` (GAP-3b):
  a fallback-served agent turn is charged to the member that ran it.
- **BREAKING (prompt shape)**: the task's session message is the input
  prompt verbatim — the `[Agent Task <id>]:` prefix is gone. The task id
  is machine bookkeeping (events, outputs, outcome registers); a
  pc-derived id in model-visible text invalidated every recorded tape's
  fingerprints and every prompt-cache prefix under ANY lowering change.
  Recorded fixtures need a one-time refresh (see
  `vaster_playground/tool/refresh_sdd_fixture.dart`).

## 0.3.0

- New optional `onTurnUsage` construction hook reporting each model turn's
  usage (measured or labeled estimate) to the wiring owner.
- Task-metadata `cacheHints` are decoded into `ModelRequest.cacheHints` —
  agent prompts now carry cache breakpoints.

## 0.2.0

- Initial version.
