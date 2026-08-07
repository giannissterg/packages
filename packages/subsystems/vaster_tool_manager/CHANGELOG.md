## 0.5.0

- **BREAKING (B3)**: `ToolManager.processFunctionCalls` is GONE — it
  was a second, ungated dispatch loop that bypassed `ToolTurnRunner`
  and emitted one tool message per call against the batching rule. Use
  `executeCall` per call; the turn pipeline builds the transcript
  message.

- **BREAKING (Rule 11 V1)**: `registerTool` returns the same-name tool
  it displaced (null when fresh) — silent overrides are observable.

## 0.2.0

- Initial version.
