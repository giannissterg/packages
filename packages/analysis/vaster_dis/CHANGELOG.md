## 0.5.0

- **BREAKING (C wave)**: `ExecutionTracer.detach` returns the restored
  observer (was bool); `attach` returns the already-displaced observer
  on the repeat-attach no-op instead of an ambiguous null.

- Rule 11 V6: `ExecutionTracer.attach` returns the displaced observer,
  `detach` whether it detached.

- `SELECT_MODEL` disassembly renders declared fallback chains in order
  (`google_ai:pro → google_ai:flash → fake:local`).

## 0.3.0

- `ExecutionTracer` moved here from `vaster_runtime` behind the dedicated
  `package:vaster_dis/tracer.dart` entrypoint — the core disassembler barrel
  stays runtime-free.

## 0.2.0

- Initial version.
