## Unreleased

- `ToolEffectRecorder` contract (GAP-3a): sealed `ToolEffectClaim`
  (`Replay`/`Slot`/`Inert`), `EffectRegion` value type riding task
  metadata, `commit` echoing the committed result (Rule 11), the
  canonical `NoopToolEffectRecorder`, and `ToolEffectRecorderBinding`
  whose `bind` returns the displaced recorder. Pure tool domain — no
  ISA, runtime, or agent knowledge.

## 0.2.0

- Initial version.
